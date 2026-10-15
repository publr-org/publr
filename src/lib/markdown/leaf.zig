//! What a line starts, read from the line alone: a quote marker, a list item, a heading, a
//! rule, a code fence, an HTML block, a table row.

const std = @import("std");

/// Up to this many spaces before a block's marker; more and it is text.
const marker_indent_max: u32 = 3;
const ordered_digits_max: u32 = 9;
pub const columns_max: u32 = 64;

pub fn indent(line: []const u8) u32 {
    std.debug.assert(line.len <= std.math.maxInt(u32));

    var count: u32 = 0;

    while (count < line.len and line[count] == ' ') {
        count += 1;
    }

    return count;
}

pub fn is_blank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t\r").len == 0;
}

/// The line with up to three leading spaces taken off; null when it has more.
fn marked(line: []const u8) ?[]const u8 {
    const spaces = indent(line);

    if (spaces > marker_indent_max) {
        return null;
    }

    std.debug.assert(spaces <= line.len);

    return line[spaces..];
}

/// What follows `>` and one space, when the line is quoted.
pub fn quote(line: []const u8) ?[]const u8 {
    const rest = marked(line) orelse return null;

    if (rest.len == 0 or rest[0] != '>') {
        return null;
    }

    const after = rest[1..];

    std.debug.assert(after.len < line.len);

    return if (after.len > 0 and after[0] == ' ') after[1..] else after;
}

pub const Item = struct {
    ordered: bool,
    /// `-`, `*` or `+`; `.` or `)` after a number.
    marker: u8,
    start: u32,
    /// How far the item's own lines are indented, from the line's start.
    content_indent: u32,
    content: []const u8,
};

/// A list item's marker and what follows it.
pub fn item(line: []const u8) ?Item {
    const spaces = indent(line);
    const rest = marked(line) orelse return null;

    if (rest.len == 0) {
        return null;
    }

    var marker_len: u32 = 1;
    var start: u32 = 0;
    var marker = rest[0];
    const ordered = std.ascii.isDigit(rest[0]);

    if (ordered) {
        while (marker_len <= ordered_digits_max and marker_len < rest.len and
            std.ascii.isDigit(rest[marker_len]))
        {
            marker_len += 1;
        }

        if (marker_len > ordered_digits_max or marker_len == rest.len) {
            return null;
        }

        start = std.fmt.parseInt(u32, rest[0..marker_len], 10) catch return null;
        marker = rest[marker_len];
        marker_len += 1;
    }

    if (std.mem.indexOfScalar(u8, if (ordered) ".)" else "-*+", marker) == null) {
        return null;
    }

    const after = rest[marker_len..];

    if (after.len > 0 and after[0] != ' ') {
        return null;
    }

    const gap = @min(@max(indent(after), 1), 4);
    const wide = indent(after) > 4;
    const taken: u32 = if (wide or after.len == 0) 1 else gap;

    std.debug.assert(taken >= 1);

    return .{
        .ordered = ordered,
        .marker = marker,
        .start = start,
        .content_indent = spaces + marker_len + taken,
        .content = if (after.len == 0) "" else after[@min(taken, after.len)..],
    };
}

/// `---`, `***` or `___`, three or more, spaces between allowed.
pub fn is_rule(line: []const u8) bool {
    const rest = marked(line) orelse return false;

    if (rest.len == 0 or std.mem.indexOfScalar(u8, "-*_", rest[0]) == null) {
        return false;
    }

    var count: u32 = 0;

    for (rest) |char| {
        if (char == rest[0]) {
            count += 1;
        } else if (char != ' ' and char != '\t') {
            return false;
        }
    }

    std.debug.assert(count >= 1);

    return count >= 3;
}

pub const Heading = struct {
    level: u32,
    text: []const u8,
};

/// `# Title` to `###### Title`, a closing run of `#` dropped.
pub fn heading(line: []const u8) ?Heading {
    const rest = marked(line) orelse return null;
    var level: u32 = 0;

    while (level < rest.len and rest[level] == '#') {
        level += 1;
    }

    if (level == 0 or level > 6 or (level < rest.len and rest[level] != ' ')) {
        return null;
    }

    var text = std.mem.trim(u8, rest[level..], " \t");
    const hashes = std.mem.trimEnd(u8, text, "#");

    if (hashes.len == 0 or hashes[hashes.len - 1] == ' ') {
        text = std.mem.trimEnd(u8, hashes, " \t");
    }

    std.debug.assert(level >= 1 and level <= 6);

    return .{
        .level = level,
        .text = text,
    };
}

pub const Fence = struct {
    char: u8,
    len: u32,
    indent: u32,
    /// The info string's first word: the code's language.
    language: []const u8,
};

pub fn fence_open(line: []const u8) ?Fence {
    const spaces = indent(line);
    const rest = marked(line) orelse return null;

    if (rest.len < 3 or (rest[0] != '`' and rest[0] != '~')) {
        return null;
    }

    var len: u32 = 0;

    while (len < rest.len and rest[len] == rest[0]) {
        len += 1;
    }

    const info = std.mem.trim(u8, rest[len..], " \t");

    if (len < 3 or (rest[0] == '`' and std.mem.indexOfScalar(u8, info, '`') != null)) {
        return null;
    }

    const word_end = std.mem.indexOfAny(u8, info, " \t") orelse info.len;

    std.debug.assert(word_end <= info.len);

    return .{
        .char = rest[0],
        .len = len,
        .indent = spaces,
        .language = info[0..word_end],
    };
}

pub fn fence_closes(line: []const u8, fence: Fence) bool {
    std.debug.assert(fence.len >= 3);

    const rest = marked(line) orelse return false;
    const run = std.mem.trimStart(u8, rest, &.{fence.char});
    const len = rest.len - run.len;

    return len >= fence.len and is_blank(run);
}

/// A line starting with a tag, a closing tag or a comment opens an HTML block.
pub fn html_start(line: []const u8) bool {
    const rest = marked(line) orelse return false;

    if (rest.len < 2 or rest[0] != '<') {
        return false;
    }

    const after = if (rest[1] == '/') rest[2..] else rest[1..];

    std.debug.assert(after.len < rest.len);

    return std.mem.startsWith(u8, rest, "<!--") or
        (after.len > 0 and std.ascii.isAlphabetic(after[0]));
}

/// Whether a line opens something other than a paragraph's next line.
pub fn starts_block(line: []const u8) bool {
    if (is_blank(line)) {
        return true;
    }

    const opens_item = if (item(line)) |found| found.content.len > 0 else false;

    std.debug.assert(line.len > 0);

    return quote(line) != null or opens_item or heading(line) != null or
        fence_open(line) != null or is_rule(line) or html_start(line);
}

/// A table row's cells, trimmed: split on `|` not escaped, the outer pipes dropped. At most
/// `columns_max`; the rest are dropped.
pub fn cells(arena: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var row = std.mem.trim(u8, line, " \t");

    if (row.len > 0 and row[0] == '|') {
        row = row[1..];
    }

    if (row.len > 0 and row[row.len - 1] == '|' and (row.len < 2 or row[row.len - 2] != '\\')) {
        row = row[0 .. row.len - 1];
    }

    var list: std.ArrayList([]const u8) = .empty;
    var start: u32 = 0;
    var index: u32 = 0;

    while (index <= row.len and list.items.len < columns_max) : (index += 1) {
        if (index + 1 < row.len and row[index] == '\\') {
            index += 1;
            continue;
        }

        if (index == row.len or row[index] == '|') {
            try list.append(arena, std.mem.trim(u8, row[start..@min(index, row.len)], " \t"));
            start = index + 1;
        }
    }

    std.debug.assert(list.items.len <= columns_max);

    return list.items;
}

/// `| --- | :---: |`: every cell dashes, a colon on either side allowed.
pub fn is_delimiter_row(row: []const []const u8) bool {
    if (row.len == 0) {
        return false;
    }

    for (row) |cell| {
        const dashes = std.mem.trim(u8, cell, ":");

        if (dashes.len == 0 or cell.len - dashes.len > 2) {
            return false;
        }

        for (dashes) |char| {
            if (char != '-') {
                return false;
            }
        }
    }

    std.debug.assert(row.len > 0);

    return true;
}

test {
    _ = @import("leaf_tests.zig");
}
