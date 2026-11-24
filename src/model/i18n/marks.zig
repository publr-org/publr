//! The messages marked for translators in a file's text: `Publr.t("…")`,
//! `Publr.tx("context", "…")`, `Publr.tn("one", "other", count)` in PTSX, `translated("…")`,
//! `translated_in` and `translated_count` in the admin's Zig, a plugin's `ctx.t("…")`,
//! `ctx.tn("one", "other", count)` and `publr.t("…")`; and the labels a declaration writes.
//! What the template script, the build's coverage count and a plugin's docs module read.
const std = @import("std");

pub const file_bytes_max: u32 = 4 << 20;

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
        .pattern = "translated(",
        .kind = .text,
    },
    // A plugin's Zig: `ctx.t("…", …)`, `ctx.tn("one", "other", count, …)`, `publr.t`.
    .{
        .pattern = ".tn(",
        .kind = .plural,
    },
    .{
        .pattern = ".t(",
        .kind = .text,
    },
};

pub const Message = struct {
    /// Whose words: `publr`, or a plugin's name (`--domain`).
    domain: []const u8 = "",
    context: []const u8,
    id: []const u8,
    plural: []const u8,
    places: std.ArrayList([]const u8) = .empty,
};

pub fn wanted(path: []const u8) bool {
    std.debug.assert(path.len > 0);

    const skipped = std.mem.indexOf(u8, path, ".zig-cache") != null or
        std.mem.indexOf(u8, path, "node_modules") != null or
        std.mem.indexOf(u8, path, "zig-out") != null;
    const kind = std.mem.endsWith(u8, path, ".ptsx") or std.mem.endsWith(u8, path, ".ts") or
        std.mem.endsWith(u8, path, ".publr") or std.mem.endsWith(u8, path, ".zig");

    return kind and !skipped;
}

/// Every marked message in one file.
pub fn scan(
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
pub fn scan_declared(
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

        if (std.ascii.isLower(mark.pattern[0]) and word) {
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

            if (text[cursor.*] == 'u') {
                try unicode_escape(arena, text, cursor, &out);
                continue;
            }

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

/// `\u{2026}` (Zig) or `\u2026` (JavaScript) at `cursor`, on its `u`, written as UTF-8;
/// the cursor left on the escape's last character.
fn unicode_escape(
    arena: std.mem.Allocator,
    text: []const u8,
    cursor: *u32,
    out: *std.ArrayList(u8),
) !void {
    std.debug.assert(text[cursor.*] == 'u');

    const braced = cursor.* + 1 < text.len and text[cursor.* + 1] == '{';
    const start = cursor.* + 1 + @intFromBool(braced);
    const end: u32 = if (braced)
        @intCast(std.mem.indexOfScalarPos(u8, text, start, '}') orelse return error.NotLiteral)
    else
        start + 4;

    if (end > text.len or end == start) {
        return error.NotLiteral;
    }

    const code = std.fmt.parseInt(u21, text[start..end], 16) catch return error.NotLiteral;
    var encoded: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(code, &encoded) catch return error.NotLiteral;

    try out.appendSlice(arena, encoded[0..length]);
    cursor.* = if (braced) end else end - 1;

    std.debug.assert(cursor.* < text.len);
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

test "a plugin's marks, and nothing that is not a literal" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var messages: std.ArrayList(Message) = .empty;
    const text =
        \\const label = publr.t("Parcels");
        \\fn shown(ctx: *Ctx) []const u8 {
        \\    _ = ctx.tn("{count} parcel", "{count} parcels", 2, .{});
        \\    _ = untranslated("Not this");
        \\    _ = ctx.t(name, .{});
        \\    return ctx.t("Sent", .{});
        \\}
    ;

    try scan(arena, "main.zig", text, "lockers", &messages);

    try std.testing.expectEqual(@as(usize, 3), messages.items.len);
    try std.testing.expectEqualStrings("Parcels", messages.items[0].id);
    try std.testing.expectEqualStrings("{count} parcels", messages.items[1].plural);
    try std.testing.expectEqualStrings("Sent", messages.items[2].id);
    try std.testing.expectEqualStrings("lockers", messages.items[2].domain);
}

test "PTSX marks with a context" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var messages: std.ArrayList(Message) = .empty;

    const text = "{Publr.tx(\"verb\", \"Post\")} {Publr.t(\"Save\")}";

    try scan(arena, "Page.ptsx", text, "", &messages);

    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expectEqualStrings("verb", messages.items[0].context);
    try std.testing.expectEqualStrings("Save", messages.items[1].id);
    try std.testing.expect(wanted("ui/Page.ptsx"));
    try std.testing.expect(!wanted("zig-out/Page.ptsx"));
}
