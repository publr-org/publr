//! The core kinds' own rules over one value: what a slug, an email, a url, a select and a
//! datetime must look like once the value has the right storage shape.
const std = @import("std");
const time = @import("../../lib/time.zig");
const field = @import("../field.zig");
const options = @import("../field/options.zig");

const Def = field.Def;
const Problems = field.Problems;
const Value = std.json.Value;

pub const string_len_max: u32 = 64 << 10;

pub const Check = *const fn (def: Def, value: Value, path: []const u8, problems: *Problems) void;

pub fn slug(def: Def, value: Value, path: []const u8, problems: *Problems) void {
    std.debug.assert(def.name.len > 0);
    std.debug.assert(path.len > 0);

    if (value != .string) {
        return;
    }

    if (!valid_slug(value.string)) {
        problems.add(path, "slug must be [a-z0-9] and hyphens");

        return;
    }

    if (options.contains(def.options.slug.reserved, value.string)) {
        const message = def.options.messages.reserved;

        problems.add(path, if (message.len > 0) message else "this slug is reserved");
    }
}

pub fn email(def: Def, value: Value, path: []const u8, problems: *Problems) void {
    std.debug.assert(def.name.len > 0);
    std.debug.assert(path.len > 0);

    if (value != .string) {
        return;
    }

    const at = std.mem.indexOfScalar(u8, value.string, '@') orelse {
        problems.add(path, "not an email");

        return;
    };

    if (value.string.len < 3 or at + 1 >= value.string.len) {
        problems.add(path, "not an email");

        return;
    }

    const domains = def.options.email.domains;

    if (domains.len > 0 and !options.contains(domains, value.string[at + 1 ..])) {
        const message = def.options.messages.domain;

        problems.add(path, if (message.len > 0) message else "not an allowed email domain");
    }
}

pub fn url(def: Def, value: Value, path: []const u8, problems: *Problems) void {
    std.debug.assert(def.name.len > 0);
    std.debug.assert(path.len > 0);

    if (value != .string) {
        return;
    }

    const text = value.string;
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse {
        problems.add(path, "url must start with a scheme, http:// or https://");

        return;
    };
    const scheme = text[0..colon];

    if (!options.scheme_allowed(def.options.url, scheme)) {
        const message = def.options.messages.scheme;

        problems.add(path, if (message.len > 0) message else "not an allowed url scheme");

        return;
    }

    const hosts = def.options.url.hosts;
    const rest = text[colon + 1 ..];
    const has_host = std.mem.startsWith(u8, rest, "//");

    if (hosts.len > 0 and has_host and !options.contains(hosts, host_of(rest))) {
        const message = def.options.messages.host;

        problems.add(path, if (message.len > 0) message else "not an allowed host");
    }
}

/// What follows the `//` up to the first `/`, `?` or `#`.
fn host_of(rest: []const u8) []const u8 {
    std.debug.assert(std.mem.startsWith(u8, rest, "//"));
    std.debug.assert(string_len_max > 0);

    const after = rest[2..];
    const end = std.mem.indexOfAny(u8, after, "/?#") orelse after.len;

    return after[0..end];
}

pub fn select(def: Def, value: Value, path: []const u8, problems: *Problems) void {
    std.debug.assert(def.options.choices.len <= field.choices_max);
    std.debug.assert(path.len > 0);

    if (value != .string) {
        return;
    }

    for (def.options.choices) |choice| {
        if (std.mem.eql(u8, choice, value.string)) {
            return;
        }
    }

    problems.add(path, "not one of the choices");
}

pub fn datetime(def: Def, value: Value, path: []const u8, problems: *Problems) void {
    std.debug.assert(def.name.len > 0);
    std.debug.assert(path.len > 0);

    if (value == .integer and (value.integer < 0 or value.integer >= time.ms_max)) {
        problems.add(path, "datetime is milliseconds since 1970");
    }
}

pub fn valid_slug(text: []const u8) bool {
    std.debug.assert(string_len_max > 0);

    if (text.len == 0 or text.len > string_len_max) {
        return false;
    }

    for (text, 0..) |char, index| {
        const lower = char >= 'a' and char <= 'z';
        const digit = char >= '0' and char <= '9';
        const hyphen = char == '-' and index > 0 and index + 1 < text.len;

        if (!(lower or digit or hyphen)) {
            return false;
        }
    }

    return true;
}

test "the kinds' own checks" {
    var problems: Problems = .{};
    const mail_def: Def = .{ .name = "mail", .label = "Mail", .kind = "email" };
    const select_def: Def = .{
        .name = "kind",
        .label = "Kind",
        .kind = "select",
        .options = .{ .choices = &.{ "a", "b" } },
    };

    email(mail_def, .{ .string = "x@y" }, "mail", &problems);
    url(mail_def, .{ .string = "https://x" }, "url", &problems);
    select(select_def, .{ .string = "b" }, "kind", &problems);
    datetime(mail_def, .{ .integer = 0 }, "at", &problems);
    slug(mail_def, .{ .string = "a-1" }, "slug", &problems);
    try std.testing.expect(problems.is_empty());

    email(mail_def, .{ .string = "nope" }, "mail", &problems);
    url(mail_def, .{ .string = "ftp://x" }, "url", &problems);
    select(select_def, .{ .string = "z" }, "kind", &problems);
    datetime(mail_def, .{ .integer = -1 }, "at", &problems);
    slug(mail_def, .{ .string = "Bad Slug" }, "slug", &problems);
    try std.testing.expectEqual(@as(u32, 5), problems.len);
    try std.testing.expect(valid_slug("hello-1"));
    try std.testing.expect(!valid_slug("-x"));

    var strict: Problems = .{};
    const work_mail: Def = .{ .name = "mail", .label = "Mail", .kind = "email", .options = .{
        .email = .{ .domains = &.{"publr.dev"} },
        .messages = .{ .domain = "Work addresses only" },
    } };
    email(work_mail, .{ .string = "ada@publr.dev" }, "mail", &strict);
    try std.testing.expect(strict.is_empty());
    email(work_mail, .{ .string = "ada@example.com" }, "mail", &strict);
    try std.testing.expectEqualStrings("Work addresses only", strict.items[0].message);

    var linked: Problems = .{};
    const phone: Def = .{ .name = "call", .label = "Call", .kind = "url", .options = .{
        .url = .{ .schemes = &.{ "tel", "https" }, .hosts = &.{"publr.dev"} },
    } };
    url(phone, .{ .string = "tel:+4812345678" }, "call", &linked);
    url(phone, .{ .string = "https://publr.dev/docs?x=1" }, "call", &linked);
    try std.testing.expect(linked.is_empty());
    url(phone, .{ .string = "http://publr.dev" }, "call", &linked);
    url(phone, .{ .string = "https://example.com" }, "call", &linked);
    try std.testing.expectEqual(@as(u32, 2), linked.len);
    try std.testing.expectEqualStrings("not an allowed host", linked.items[1].message);
    url(mail_def, .{ .string = "mailto:x@y" }, "url", &linked);
    try std.testing.expectEqual(@as(u32, 3), linked.len);

    var kept: Problems = .{};
    const home: Def = .{ .name = "slug", .label = "Slug", .kind = "slug", .options = .{
        .slug = .{ .reserved = &.{ "admin", "api" } },
    } };
    slug(home, .{ .string = "api" }, "slug", &kept);
    try std.testing.expectEqualStrings("this slug is reserved", kept.items[0].message);
}
