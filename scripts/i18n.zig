//! The admin's messages for translators: `zig run scripts/i18n.zig -- <dir>...` writes a
//! gettext template (`.pot`) to stdout of every message marked in the `.ptsx`, `.ts`,
//! `.publr` and `.zig` files under the folders given: `Publr.t("…")`, `Publr.tx("context", "…")`,
//! `Publr.tn("one", "other", n)`, and in Zig `translated("…")`, `translated_with("…", …)`,
//! `translated_in("context", "…")`, `translated_count("one", "other", n)`. Each message once,
//! with every place it is written.
const std = @import("std");

const files_max: u32 = 8192;
const file_bytes_max: u32 = 4 << 20;

const Kind = enum { text, context, plural };

const Mark = struct {
    pattern: []const u8,
    kind: Kind,
};

const marks = [_]Mark{
    .{
        .pattern = "Publr.tx(",
        .kind = .context,
    },
    .{
        .pattern = "Publr.tn(",
        .kind = .plural,
    },
    .{
        .pattern = "Publr.t(",
        .kind = .text,
    },
    .{
        .pattern = "translated_in(",
        .kind = .context,
    },
    .{
        .pattern = "translated_count(",
        .kind = .plural,
    },
    .{
        .pattern = "translated_with(",
        .kind = .text,
    },
    .{
        .pattern = "translated(",
        .kind = .text,
    },
};

const Message = struct {
    /// Whose words: `publr`, or a plugin's name (`--domain`).
    domain: []const u8 = "",
    context: []const u8,
    id: []const u8,
    plural: []const u8,
    places: std.ArrayList([]const u8) = .empty,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);

    if (arguments.len < 2) {
        std.debug.print("usage: zig run scripts/i18n.zig -- <dir>...\n", .{});
        std.process.exit(2);
    }

    var messages: std.ArrayList(Message) = .empty;
    var declared = false;
    var lines = false;
    var domain: []const u8 = "publr";
    var expect_domain = false;

    // `--declared` and the files after it: declarations whose `.label`, `.description` and
    // `.noun` the admin draws by name (statuses, field kinds, the sidebar's pages).
    for (arguments[1..]) |argument| {
        if (expect_domain) {
            domain = argument;
            expect_domain = false;
            declared = false;
        } else if (std.mem.eql(u8, argument, "--lines")) {
            lines = true;
        } else if (std.mem.eql(u8, argument, "--domain")) {
            expect_domain = true;
        } else if (std.mem.eql(u8, argument, "--declared")) {
            declared = true;
        } else if (declared) {
            const limit: std.Io.Limit = .limited(file_bytes_max);
            const text = try std.Io.Dir.cwd().readFileAlloc(init.io, argument, arena, limit);

            try scan_declared(arena, argument, text, domain, &messages);
        } else {
            walk(init.io, arena, argument, domain, &messages) catch |err| switch (err) {
                // A plugin without a `ui/` or with nothing marked is fine.
                error.FileNotFound => continue,
                else => return err,
            };
        }
    }

    var buffer: [64 << 10]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);

    if (lines) {
        try write_lines(&stdout.interface, messages.items);
    } else {
        try write(&stdout.interface, messages.items);
    }

    try stdout.interface.flush();

    std.debug.assert(stdout.interface.end == 0);
}

/// `domain`, tab, `context`, tab, the message, one per line, tabs and line breaks escaped:
/// what the build embeds so the admin can count what a language covers.
fn write_lines(out: *std.Io.Writer, messages: []const Message) !void {
    for (messages) |message| {
        std.debug.assert(message.places.items.len > 0);

        try escaped(out, message.domain);
        try out.writeByte('\t');
        try escaped(out, message.context);
        try out.writeByte('\t');
        try escaped(out, message.id);
        try out.writeByte('\n');
    }
}

fn escaped(out: *std.Io.Writer, text: []const u8) !void {
    std.debug.assert(text.len <= file_bytes_max);

    for (text) |char| {
        switch (char) {
            '\\' => try out.writeAll("\\\\"),
            '\t' => try out.writeAll("\\t"),
            '\n' => try out.writeAll("\\n"),
            else => try out.writeByte(char),
        }
    }
}

fn walk(
    io: std.Io,
    arena: std.mem.Allocator,
    root: []const u8,
    domain: []const u8,
    messages: *std.ArrayList(Message),
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{
        .iterate = true,
    });
    defer dir.close(io);

    var walker = try dir.walk(arena);
    defer walker.deinit();

    var paths: std.ArrayList([]const u8) = .empty;

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !wanted(entry.path)) {
            continue;
        }

        if (paths.items.len == files_max) {
            return error.TooManyFiles;
        }

        try paths.append(arena, try std.fs.path.join(arena, &.{ root, entry.path }));
    }

    std.debug.assert(paths.items.len <= files_max);

    std.mem.sort([]const u8, paths.items, {}, less);

    for (paths.items) |path| {
        const limit: std.Io.Limit = .limited(file_bytes_max);
        const text = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, limit);

        try scan(arena, path, text, domain, messages);
    }
}

fn wanted(path: []const u8) bool {
    std.debug.assert(path.len > 0);

    const skipped = std.mem.indexOf(u8, path, ".zig-cache") != null or
        std.mem.indexOf(u8, path, "node_modules") != null or
        std.mem.indexOf(u8, path, "zig-out") != null;
    const kind = std.mem.endsWith(u8, path, ".ptsx") or std.mem.endsWith(u8, path, ".ts") or
        std.mem.endsWith(u8, path, ".publr") or std.mem.endsWith(u8, path, ".zig");

    return kind and !skipped;
}

fn less(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

/// Every marked message in one file.
fn scan(
    arena: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
    domain: []const u8,
    messages: *std.ArrayList(Message),
) !void {
    std.debug.assert(text.len <= file_bytes_max);

    var index: u32 = 0;

    while (index < text.len) : (index += 1) {
        const mark = mark_at(text, index) orelse continue;
        var cursor: u32 = @intCast(index + mark.pattern.len);
        const first = string_at(arena, text, &cursor) catch continue;
        var second: []const u8 = "";

        if (mark.kind != .text) {
            second = string_at(arena, text, &cursor) catch continue;
        }

        const line = std.mem.count(u8, text[0..index], "\n") + 1;
        const place = try std.fmt.allocPrint(arena, "{s}:{d}", .{ path, line });

        try add(arena, messages, .{
            .domain = domain,
            .context = if (mark.kind == .context) first else "",
            .id = if (mark.kind == .context) second else first,
            .plural = if (mark.kind == .plural) second else "",
        }, place);
        index = cursor;
    }
}

const declared_fields = [_][]const u8{ ".label = ", ".description = ", ".noun = " };

/// Every declared label, description and noun in one file.
fn scan_declared(
    arena: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
    domain: []const u8,
    messages: *std.ArrayList(Message),
) !void {
    std.debug.assert(text.len <= file_bytes_max);

    var index: u32 = 0;

    while (index < text.len) : (index += 1) {
        for (declared_fields) |field| {
            if (!std.mem.startsWith(u8, text[index..], field)) {
                continue;
            }

            var cursor: u32 = @intCast(index + field.len);
            const value = string_at(arena, text, &cursor) catch break;

            if (value.len == 0) {
                break;
            }

            const line = std.mem.count(u8, text[0..index], "\n") + 1;
            const place = try std.fmt.allocPrint(arena, "{s}:{d}", .{ path, line });

            try add(arena, messages, .{
                .domain = domain,
                .context = "",
                .id = value,
                .plural = "",
            }, place);
            index = cursor;

            break;
        }
    }
}

fn mark_at(text: []const u8, index: u32) ?Mark {
    std.debug.assert(index < text.len);

    for (marks) |mark| {
        if (!std.mem.startsWith(u8, text[index..], mark.pattern)) {
            continue;
        }

        // `translated(` inside `untranslated(` or a longer name is not a mark.
        const before = if (index > 0) text[index - 1] else ' ';
        const word = std.ascii.isAlphanumeric(before) or before == '_';

        if (mark.pattern[0] != 'P' and word) {
            return null;
        }

        return mark;
    }

    return null;
}

/// A double-quoted string after optional blanks and a comma, unescaped, joined with the
/// strings Zig adds to it (`"a " ++ "b"`); an error for anything else (a variable, a
/// template), which is not a message to collect.
fn string_at(arena: std.mem.Allocator, text: []const u8, cursor: *u32) ![]const u8 {
    std.debug.assert(cursor.* <= text.len);

    var joined = try one_string_at(arena, text, cursor);

    while (true) {
        var ahead = cursor.*;

        while (ahead < text.len and std.ascii.isWhitespace(text[ahead])) : (ahead += 1) {}

        if (!std.mem.startsWith(u8, text[ahead..], "++")) {
            return joined;
        }

        ahead += 2;

        while (ahead < text.len and std.ascii.isWhitespace(text[ahead])) : (ahead += 1) {}

        if (ahead >= text.len or text[ahead] != '"') {
            return joined;
        }

        cursor.* = ahead;
        const next = try one_string_at(arena, text, cursor);

        joined = try std.mem.concat(arena, u8, &.{ joined, next });
    }
}

fn separates(char: u8) bool {
    return std.ascii.isWhitespace(char) or char == ',';
}

fn one_string_at(arena: std.mem.Allocator, text: []const u8, cursor: *u32) ![]const u8 {
    std.debug.assert(cursor.* <= text.len);

    while (cursor.* < text.len and separates(text[cursor.*])) {
        cursor.* += 1;
    }

    if (cursor.* >= text.len or text[cursor.*] != '"') {
        return error.NotLiteral;
    }

    cursor.* += 1;

    var out: std.ArrayList(u8) = .empty;

    while (cursor.* < text.len and text[cursor.*] != '"') : (cursor.* += 1) {
        var char = text[cursor.*];

        if (char == '\n') {
            return error.NotLiteral;
        }

        if (char == '\\' and cursor.* + 1 < text.len) {
            cursor.* += 1;
            char = switch (text[cursor.*]) {
                'n' => '\n',
                't' => '\t',
                else => text[cursor.*],
            };
        }

        try out.append(arena, char);
    }

    // A string still open at the end of the file is not a message.
    if (cursor.* >= text.len) {
        return error.NotLiteral;
    }

    cursor.* += 1;

    return out.items;
}

fn add(
    arena: std.mem.Allocator,
    messages: *std.ArrayList(Message),
    message: Message,
    place: []const u8,
) !void {
    std.debug.assert(place.len > 0);

    for (messages.items) |*known| {
        const same_domain = std.mem.eql(u8, known.domain, message.domain);
        const same_context = std.mem.eql(u8, known.context, message.context);
        const same_id = std.mem.eql(u8, known.id, message.id);

        if (same_domain and same_context and same_id) {
            try known.places.append(arena, place);

            return;
        }
    }

    var fresh = message;

    try fresh.places.append(arena, place);
    try messages.append(arena, fresh);
}

fn write(out: *std.Io.Writer, messages: []const Message) !void {
    try out.writeAll(
        \\msgid ""
        \\msgstr ""
        \\"MIME-Version: 1.0\n"
        \\"Content-Type: text/plain; charset=UTF-8\n"
        \\"Content-Transfer-Encoding: 8bit\n"
        \\
        \\
    );

    for (messages, 0..) |message, index| {
        std.debug.assert(message.places.items.len > 0);

        // A template holds each message once, whichever domains share it.
        if (written_before(messages[0..index], message)) {
            continue;
        }

        for (message.places.items) |place| {
            try out.print("#: {s}\n", .{place});
        }

        if (message.context.len > 0) {
            try quoted(out, "msgctxt", message.context);
        }

        try quoted(out, "msgid", message.id);

        if (message.plural.len > 0) {
            try quoted(out, "msgid_plural", message.plural);
            try out.writeAll("msgstr[0] \"\"\nmsgstr[1] \"\"\n\n");
        } else {
            try out.writeAll("msgstr \"\"\n\n");
        }
    }
}

fn written_before(earlier: []const Message, message: Message) bool {
    std.debug.assert(message.places.items.len > 0);

    for (earlier) |known| {
        const same_context = std.mem.eql(u8, known.context, message.context);

        if (same_context and std.mem.eql(u8, known.id, message.id)) {
            return true;
        }
    }

    return false;
}

fn quoted(out: *std.Io.Writer, keyword: []const u8, text: []const u8) !void {
    std.debug.assert(keyword.len > 0);

    try out.print("{s} \"", .{keyword});

    for (text) |char| {
        switch (char) {
            '"' => try out.writeAll("\\\""),
            '\\' => try out.writeAll("\\\\"),
            '\n' => try out.writeAll("\\n"),
            '\t' => try out.writeAll("\\t"),
            else => try out.writeByte(char),
        }
    }

    try out.writeAll("\"\n");
}
