//! Which language a visitor reads the site in: theirs once they chose (the
//! `publr_language` cookie, set to the language of every page they open, so following the
//! site's language switch is the choice), else their browser's (`Accept-Language`) on
//! their first page, when the site has it.
const std = @import("std");
const http = @import("../../lib/http.zig");
const identity = @import("../rest/identity.zig");
const languages = @import("languages.zig");

const Project = @import("../../server/project.zig").Project;
const Target = Project.Target;
const Place = @import("../../model.zig").variant.Place;
const Request = http.Request;
const Response = http.Response;

pub const cookie_name = "publr_language";
const max_age_s: u32 = 365 * 24 * 60 * 60;

/// Sends a visitor who never chose, opening a page of the main language, to the same page
/// in the first language their browser asks for that the site has. True when it did.
pub fn redirect(
    project: *const Project,
    target: Target,
    request: *Request,
    response: *Response,
) !bool {
    std.debug.assert(target.path.len > 0);

    const reading = request.method() == .get or request.method() == .head;
    const cookies = request.header("cookie") orelse "";
    const chose = identity.cookie_value(cookies, cookie_name) != null;

    if (!reading or chose or target.place.variant.len > 0) {
        return false;
    }

    const all = try languages.places(project, response.arena);

    if (all.len < 2) {
        return false;
    }

    const wanted = asked_of(all, request.header("accept-language") orelse "") orelse {
        return false;
    };
    const query = request.query();
    const page = if (std.mem.eql(u8, target.path, "/")) "" else target.path;
    const mark = if (query.len > 0) "?" else "";
    const location = try std.mem.concat(response.arena, u8, &.{
        project.base,
        wanted.address,
        page,
        mark,
        query,
    });

    try response.set_header("Vary", "Accept-Language, Cookie");
    try response.set_header("Cache-Control", "private, no-store");
    try response.redirect(.found, location);

    return true;
}

/// The first language the browser asks for, in its order, that the site has; null when
/// that is the main one (nothing to do) or none.
fn asked_of(all: []const Place, accepted: []const u8) ?Place {
    std.debug.assert(all.len >= 2);

    var ranges = std.mem.tokenizeAny(u8, accepted, ", ");

    while (ranges.next()) |range| {
        const tag = range[0 .. std.mem.indexOfScalar(u8, range, ';') orelse range.len];

        for (all) |place| {
            if (matches(tag, place.locale)) {
                return if (place.variant.len == 0) null else place;
            }
        }
    }

    return null;
}

/// `pl-PL` asks for `pl`; `pl` asks for `pl`; case does not matter.
fn matches(tag: []const u8, locale: []const u8) bool {
    std.debug.assert(locale.len > 0);

    if (std.ascii.eqlIgnoreCase(tag, locale)) {
        return true;
    }

    return tag.len > locale.len and tag[locale.len] == '-' and
        std.ascii.eqlIgnoreCase(tag[0..locale.len], locale);
}

/// The page's language as the visitor's choice from now on, when it differs from it.
pub fn remember(
    project: *const Project,
    target: Target,
    request: *Request,
    response: *Response,
) !void {
    std.debug.assert(target.path.len > 0);

    const locale = target.place.locale;
    const cookies = request.header("cookie") orelse "";
    const held = identity.cookie_value(cookies, cookie_name) orelse "";

    if (locale.len == 0 or std.mem.eql(u8, held, locale)) {
        return;
    }

    const value = try std.fmt.allocPrint(response.arena, "{s}={s}; Path=/; SameSite=Lax; " ++
        "Max-Age={d}{s}{s}{s}", .{
        cookie_name,
        locale,
        max_age_s,
        identity.domain_label(project),
        identity.domain_of(project),
        identity.secure_suffix(request),
    });

    try response.add_header("Set-Cookie", value);
}

test "the browser's first language the site has" {
    const all = [_]Place{
        .{
            .variant = "",
            .locale = "en",
            .address = "",
        },
        .{
            .variant = "pl",
            .locale = "pl",
            .address = "/pl",
        },
    };

    try std.testing.expectEqualStrings("/pl", asked_of(&all, "pl-PL,pl;q=0.9,en;q=0.8").?.address);
    try std.testing.expect(asked_of(&all, "en-US,pl;q=0.5") == null);
    try std.testing.expect(asked_of(&all, "de-DE") == null);
    try std.testing.expect(asked_of(&all, "") == null);
    try std.testing.expect(!matches("plx", "pl"));
}
