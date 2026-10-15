//! A command an agent ran, as a person follows it: one readable line ("Created content
//! type Recipe") and the admin page that shows what it changed. Read from the command's
//! words and what it answered; a command not known here reads as its own name.

const std = @import("std");

pub const Presented = struct {
    label: []const u8,
    /// The admin page to show; empty to stay where the person is.
    href: []const u8 = "",
};

/// `args` as after `publr`; `output` what it printed, JSON when it succeeded.
pub fn present(
    arena: std.mem.Allocator,
    args: []const []const u8,
    output: []const u8,
) !Presented {
    std.debug.assert(args.len <= 64);
    std.debug.assert(output.len <= std.math.maxInt(u32));

    if (args.len == 0) {
        return .{
            .label = "Ran publr",
        };
    }

    if (std.mem.eql(u8, args[0], "--help")) {
        return .{
            .label = "Read the help",
        };
    }

    if (args.len == 1 or std.mem.eql(u8, args[args.len - 1], "--help")) {
        return .{
            .label = try std.fmt.allocPrint(arena, "Read the help for {s}", .{args[0]}),
        };
    }

    const command: Command = .{
        .arena = arena,
        .namespace = args[0],
        .verb = args[1],
        .flags = args[2..],
        .answer = parsed(arena, output),
    };

    if (command.is("content_type")) {
        return command.content_type();
    }

    if (command.is("record")) {
        return command.record();
    }

    if (command.is("plugin")) {
        return command.named("plugin", "--name", "/admin/settings/plugins");
    }

    if (command.is("taxonomy")) {
        return command.named("taxonomy", "--handle", "/admin/structure/taxonomies");
    }

    if (command.is("media")) {
        return .{
            .label = try sentence(arena, command.verb, "media", ""),
            .href = "/admin/media",
        };
    }

    if (command.is("apps")) {
        const path = flag(command.flags, "--path") orelse "";

        // The page a write becomes is the server's to say (`agent/site_page.zig`).
        if (std.mem.eql(u8, command.verb, "load")) {
            return .{
                .label = "Put the site's changes live",
            };
        }

        return .{
            .label = try sentence(arena, command.verb, "app file", path),
        };
    }

    const words = .{ command.namespace, command.verb };
    const label = try std.fmt.allocPrint(arena, "Ran {s} {s}", words);

    return .{
        .label = label,
    };
}

const Command = struct {
    arena: std.mem.Allocator,
    namespace: []const u8,
    verb: []const u8,
    flags: []const []const u8,
    answer: ?std.json.Value,

    fn is(command: Command, namespace: []const u8) bool {
        std.debug.assert(namespace.len > 0);
        std.debug.assert(command.namespace.len > 0);

        return std.mem.eql(u8, command.namespace, namespace);
    }

    fn reads(command: Command) bool {
        std.debug.assert(command.verb.len > 0);

        const verbs = [_][]const u8{ "list", "get", "query", "validate" };

        for (verbs) |verb| {
            if (std.mem.eql(u8, verb, command.verb)) {
                return true;
            }
        }

        return false;
    }

    /// A thing named by `name_flag`, whose page is `<list>/<name>`.
    fn named(
        command: Command,
        what: []const u8,
        name_flag: []const u8,
        list: []const u8,
    ) !Presented {
        std.debug.assert(what.len > 0);
        std.debug.assert(list.len > 0);

        const name = flag(command.flags, name_flag) orelse
            field(command.answer, "handle") orelse "";
        const one = if (name.len > 0) try page(command.arena, list, name) else "";

        return .{
            .label = try sentence(command.arena, command.verb, what, name),
            .href = if (one.len > 0) one else list,
        };
    }

    fn content_type(command: Command) !Presented {
        std.debug.assert(command.verb.len > 0);

        if (std.mem.eql(u8, command.verb, "validate")) {
            return .{
                .label = "Checked a content type definition",
            };
        }

        if (command.reads()) {
            return .{
                .label = "Looked at the content types",
                .href = "/admin/types",
            };
        }

        const definition = parsed(command.arena, flag(command.flags, "--definition") orelse "");
        const handle = field(definition, "handle") orelse flag(command.flags, "--type") orelse
            field(command.answer, "handle") orelse "";
        const name = field(definition, "name") orelse handle;
        const one = if (handle.len > 0) try page(command.arena, "/admin/types", handle) else "";

        return .{
            .label = try sentence(command.arena, command.verb, "content type", name),
            .href = if (one.len > 0) one else "/admin/types",
        };
    }

    fn record(command: Command) !Presented {
        std.debug.assert(command.verb.len > 0);

        const arena = command.arena;
        const handle = flag(command.flags, "--type") orelse field(command.answer, "type") orelse "";
        const plain = handle.len > 0 and (try page(arena, "/admin", handle)).len > 0;
        const href = if (plain)
            try std.fmt.allocPrint(arena, "/admin/content?type={s}", .{handle})
        else
            "/admin/content";
        const what = if (handle.len > 0) handle else "record";

        if (command.reads()) {
            const label = if (handle.len > 0)
                try std.fmt.allocPrint(arena, "Looked at the {s} records", .{handle})
            else
                "Looked at the records";

            return .{
                .label = label,
                .href = href,
            };
        }

        const document = parsed(arena, flag(command.flags, "--document") orelse "");
        const title = field(document, "title") orelse field(document, "name") orelse "";
        const subject = if (title.len > 0)
            try std.fmt.allocPrint(arena, "{s} \u{201C}{s}\u{201D}", .{ what, title })
        else
            what;
        // A write shows the record itself, where the change can be seen; a removal shows the
        // list it left, where a person deleting it lands too.
        const id = flag(command.flags, "--id") orelse field(command.answer, "id") orelse "";
        const removes = std.mem.eql(u8, command.verb, "delete") or
            std.mem.eql(u8, command.verb, "purge");
        const own = if (id.len > 0 and id.len <= 64 and !removes)
            try std.fmt.allocPrint(arena, "/admin/content/{s}", .{id})
        else
            href;

        return .{
            .label = try sentence(arena, command.verb, subject, ""),
            .href = own,
        };
    }
};

/// "Created content type Recipe", "Published post", "Ran record purge".
fn sentence(
    arena: std.mem.Allocator,
    verb: []const u8,
    what: []const u8,
    name: []const u8,
) ![]const u8 {
    std.debug.assert(verb.len > 0);
    std.debug.assert(what.len > 0);

    const done = past_of(verb) orelse {
        return std.fmt.allocPrint(arena, "Ran {s} {s}", .{ what, verb });
    };
    const separator: []const u8 = if (name.len > 0) " " else "";

    return std.fmt.allocPrint(arena, "{s} {s}{s}{s}", .{ done, what, separator, name });
}

fn past_of(verb: []const u8) ?[]const u8 {
    std.debug.assert(verb.len > 0);

    const pairs = [_][2][]const u8{
        .{ "create", "Created" },
        .{ "update", "Changed" },
        .{ "save", "Saved" },
        .{ "delete", "Deleted" },
        .{ "publish", "Published" },
        .{ "add", "Added" },
        .{ "build", "Built" },
        .{ "write", "Wrote" },
        .{ "upload", "Uploaded" },
        .{ "enable", "Enabled" },
        .{ "add_field", "Added a field to" },
        .{ "list", "Looked at" },
        .{ "get", "Looked at" },
        .{ "read", "Read" },
        .{ "files", "Looked at" },
        .{ "sources", "Sent the sources of" },
        .{ "install", "Installed" },
        .{ "rename", "Renamed" },
    };

    for (pairs) |pair| {
        if (std.mem.eql(u8, pair[0], verb)) {
            return pair[1];
        }
    }

    return null;
}

/// `<list>/<value>`, when `value` is a plain handle or name; else empty.
fn page(arena: std.mem.Allocator, list: []const u8, value: []const u8) ![]const u8 {
    std.debug.assert(value.len > 0);
    std.debug.assert(list.len > 0);

    for (value) |byte| {
        const plain = std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';

        if (!plain) {
            return "";
        }
    }

    return std.fmt.allocPrint(arena, "{s}/{s}", .{ list, value });
}

/// The value after `name` among `flags`.
fn flag(flags: []const []const u8, name: []const u8) ?[]const u8 {
    std.debug.assert(name.len > 2);

    for (flags, 0..) |word, index| {
        if (std.mem.eql(u8, word, name) and index + 1 < flags.len) {
            return flags[index + 1];
        }
    }

    return null;
}

fn parsed(arena: std.mem.Allocator, text: []const u8) ?std.json.Value {
    std.debug.assert(text.len <= std.math.maxInt(u32));

    if (text.len == 0 or text[0] != '{' and text[0] != '[' and !std.ascii.isWhitespace(text[0])) {
        return null;
    }

    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch null;
}

/// A string field of a JSON object.
fn field(value: ?std.json.Value, name: []const u8) ?[]const u8 {
    std.debug.assert(name.len > 0);

    const object = switch (value orelse return null) {
        .object => |object| object,
        else => return null,
    };

    return switch (object.get(name) orelse return null) {
        .string => |text| if (text.len > 0) text else null,
        else => null,
    };
}

test "commands read as what they did, with the page that shows it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const created = try present(arena, &.{
        "content_type", "create", "--definition", "{\"handle\":\"recipe\",\"name\":\"Recipe\"}",
    }, "{}");
    try std.testing.expectEqualStrings("Created content type Recipe", created.label);
    try std.testing.expectEqualStrings("/admin/types/recipe", created.href);

    const added = try present(arena, &.{
        "record", "create", "--type", "recipe", "--document", "{\"title\":\"Tomato soup\"}",
    }, "{\"id\":\"x\"}");
    try std.testing.expectEqualStrings("Created recipe \u{201C}Tomato soup\u{201D}", added.label);
    // A write shows the record itself.
    try std.testing.expectEqualStrings("/admin/content/x", added.href);

    // A removal shows the list the record left.
    const deleted = try present(arena, &.{
        "record", "delete", "--id", "x",
    }, "{\"type\":\"recipe\"}");
    try std.testing.expectEqualStrings("/admin/content?type=recipe", deleted.href);

    const help = try present(arena, &.{ "record", "--help" }, "");
    try std.testing.expectEqualStrings("Read the help for record", help.label);

    const odd = try present(arena, &.{ "record", "purge", "--id", "x" }, "");
    try std.testing.expectEqualStrings("Ran record purge", odd.label);

    const hostile = try present(arena, &.{ "plugin", "build", "--name", "a/../b" }, "");
    try std.testing.expectEqualStrings("/admin/settings/plugins", hostile.href);
}
