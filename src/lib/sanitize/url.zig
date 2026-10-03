//! Attribute values for the sanitizer: entities decoded before anything is judged (so
//! `jav&#x61;script:` is seen for what it is), and addresses kept only when they are
//! `http(s)`, `mailto` or a path on the site.

const std = @import("std");

/// The value with its character references decoded: `&amp;`, `&lt;`, `&gt;`, `&quot;`,
/// `&#39;`, `&apos;`, `&#NN;`, `&#xHH;`. Any other `&` is kept as it is.
pub fn decode(arena: std.mem.Allocator, value: []const u8) ![]const u8 {
    std.debug.assert(value.len <= 4 << 20);

    if (std.mem.indexOfScalar(u8, value, '&') == null) {
        return value;
    }

    var out: std.ArrayList(u8) = .empty;
    var index: u32 = 0;

    while (index < value.len) {
        const length = if (value[index] == '&') entity_length(value[index..]) else 0;

        if (length == 0) {
            try out.append(arena, value[index]);
            index += 1;
            continue;
        }

        try append_decoded(arena, &out, value[index .. index + length]);
        index += length;
    }

    return out.items;
}

fn append_decoded(arena: std.mem.Allocator, out: *std.ArrayList(u8), entity: []const u8) !void {
    std.debug.assert(entity.len >= 3 and entity[0] == '&');

    const body = entity[1 .. entity.len - 1];
    const named = [_][2][]const u8{
        .{ "amp", "&" }, .{ "lt", "<" }, .{ "gt", ">" }, .{ "quot", "\"" }, .{ "apos", "'" },
    };

    for (named) |pair| {
        if (std.mem.eql(u8, body, pair[0])) {
            return out.appendSlice(arena, pair[1]);
        }
    }

    if (body[0] != '#') {
        return out.appendSlice(arena, entity);
    }

    const hex = body.len > 1 and (body[1] == 'x' or body[1] == 'X');
    const digits = if (hex) body[2..] else body[1..];
    const code = std.fmt.parseInt(u21, digits, if (hex) 16 else 10) catch 0xFFFD;
    var buffer: [4]u8 = undefined;
    const valid = std.unicode.utf8ValidCodepoint(code) and code != 0;
    const length = std.unicode.utf8Encode(if (valid) code else 0xFFFD, &buffer) catch 0;

    try out.appendSlice(arena, buffer[0..length]);
}

/// How long the character reference at the start of `text` is, or 0 when it is not one:
/// `&name;` (letters and digits, up to 32), `&#digits;`, `&#xhex;`.
pub fn entity_length(text: []const u8) u32 {
    std.debug.assert(text.len > 0 and text[0] == '&');

    var index: u32 = 1;
    const numeric = index < text.len and text[index] == '#';

    if (numeric) {
        index += 1;

        if (index < text.len and (text[index] == 'x' or text[index] == 'X')) {
            index += 1;
        }
    }

    const start = index;

    while (index < text.len and index - start <= 32 and std.ascii.isAlphanumeric(text[index])) {
        index += 1;
    }

    if (index == start or index >= text.len or text[index] != ';') {
        return 0;
    }

    return index + 1;
}

/// Whether an address (decoded) may stay: `http://`, `https://`, `mailto:`, or a path on
/// the site (`/x`, `#x`, `?x`, `x/y`). Never `javascript:`, `data:`, `vbscript:` or any
/// scheme hidden behind spaces or control characters; never `//host`.
pub fn safe(address: []const u8) bool {
    std.debug.assert(address.len <= 4 << 20);

    for (address) |char| {
        if (char < 0x21 or char == 0x7f or char == '\\') {
            return false;
        }
    }

    if (address.len == 0) {
        return true;
    }

    const schemes = [_][]const u8{ "http://", "https://", "mailto:" };

    for (schemes) |scheme| {
        if (std.ascii.startsWithIgnoreCase(address, scheme)) {
            return true;
        }
    }

    if (std.mem.startsWith(u8, address, "//")) {
        return false;
    }

    const colon = std.mem.indexOfScalar(u8, address, ':') orelse return true;
    const end = std.mem.indexOfAny(u8, address, "/?#") orelse address.len;

    return colon > end;
}
