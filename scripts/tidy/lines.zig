const std = @import("std");
const limits = @import("limits.zig");

const file_bytes_max = limits.file_bytes_max;
const line_len_max = limits.line_len_max;

pub const Rule = struct {
    message: []const u8,
    check: *const fn (line: []const u8) bool,
};

pub const rules = [_]Rule{
    .{
        .message = "line is over 100 columns",
        .check = line_too_long,
    },
    .{
        .message = "trailing whitespace",
        .check = trailing_whitespace,
    },
    .{
        .message = "top-level var (global mutable state)",
        .check = top_level_var,
    },
    .{
        .message = "usize in a declaration: use u32/u64",
        .check = sized_declaration,
    },
    .{
        .message = "empty catch swallows an error",
        .check = swallowed_error,
    },
    .{
        .message = "single-letter identifier: use a full name",
        .check = short_identifier,
    },
    .{
        .message = "abbreviated identifier: use a full name",
        .check = abbreviated_identifier,
    },
};

const banned_abbreviations = [_][]const u8{
    "stmt", "fba",  "rc",  "tx",   "cfg",  "msg",  "idx", "cnt", "tmp", "res",
    "req",  "resp", "val", "ret",  "num",  "str",  "arr", "obj", "cb",  "ev",
    "mw",   "conn", "cur", "prev", "elem", "iter", "op",  "ops",
};

const segment_len_max: u32 = 64;

fn line_too_long(line: []const u8) bool {
    const width = std.unicode.utf8CountCodepoints(line) catch line.len;
    return width > line_len_max;
}

fn trailing_whitespace(line: []const u8) bool {
    std.debug.assert(line.len < file_bytes_max);
    std.debug.assert(line_len_max > 0);

    if (line.len == 0) {
        return false;
    }

    return line[line.len - 1] == ' ' or line[line.len - 1] == '\t';
}

pub fn top_level_var(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "var ") or std.mem.startsWith(u8, line, "pub var ");
}

fn sized_declaration(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " ");

    std.debug.assert(trimmed.len <= line.len);
    std.debug.assert(usize_word.len == 5);

    const is_const = std.mem.startsWith(u8, trimmed, "const ") or
        std.mem.startsWith(u8, trimmed, "pub const ");
    const is_fn = std.mem.indexOf(u8, trimmed, "fn ") != null;
    const is_field = std.mem.endsWith(u8, trimmed, typed_usize ++ ",") or
        std.mem.endsWith(u8, trimmed, typed_usize);

    if (std.mem.indexOf(u8, trimmed, usize_word) == null) {
        return false;
    }

    if (is_field) {
        return true;
    }

    if (is_const) {
        return std.mem.indexOf(u8, trimmed, typed_usize) != null;
    }

    if (is_fn) {
        return true;
    }

    return false;
}

fn swallowed_error(line: []const u8) bool {
    return std.mem.indexOf(u8, line, empty_catch) != null;
}

fn short_identifier(line: []const u8) bool {
    var index: u32 = 0;

    while (index < line.len) : (index += 1) {
        if (!std.ascii.isAlphabetic(line[index])) {
            continue;
        }

        const start = index;
        while (index < line.len and is_identifier_char(line[index])) index += 1;

        std.debug.assert(index > start);
        std.debug.assert(index <= line.len);

        const word = line[start..index];
        if (word.len != 1) {
            continue;
        }
        if (start == 0) {
            continue;
        }
        if (!declares_identifier(line, start, index)) {
            continue;
        }
        // The translation function keeps gettext's name, as `Publr.t` does in templates.
        const translation = std.mem.indexOf(u8, line, "pub fn t(") != null or
            std.mem.indexOf(u8, line, "pub const t = ") != null;

        if (translation) {
            continue;
        }

        return true;
    }

    return false;
}

fn abbreviated_identifier(line: []const u8) bool {
    var index: u32 = 0;

    while (index < line.len) : (index += 1) {
        if (!std.ascii.isAlphabetic(line[index]) and line[index] != '_') {
            continue;
        }

        const start = index;
        while (index < line.len and is_identifier_char(line[index])) index += 1;

        std.debug.assert(index > start);
        std.debug.assert(index <= line.len);

        const word = line[start..index];

        if (start == 0) {
            continue;
        }

        if (!declares_identifier(line, start, index)) {
            continue;
        }

        if (has_banned_segment(word)) {
            return true;
        }
    }

    return false;
}

fn has_banned_segment(word: []const u8) bool {
    std.debug.assert(word.len > 0);

    var segment_start: u32 = 0;
    var index: u32 = 1;

    while (index <= word.len) : (index += 1) {
        const at_end = index == word.len;
        const boundary = at_end or word[index] == '_' or
            (std.ascii.isUpper(word[index]) and std.ascii.isLower(word[index - 1]));

        if (!boundary) {
            continue;
        }

        if (is_banned_segment(word[segment_start..index])) {
            return true;
        }

        segment_start = if (at_end) index else if (word[index] == '_') index + 1 else index;
        std.debug.assert(segment_start <= word.len);
    }

    return false;
}

fn is_banned_segment(segment: []const u8) bool {
    std.debug.assert(banned_abbreviations.len > 0);
    std.debug.assert(segment_len_max >= 8);

    var lowered: [segment_len_max]u8 = undefined;

    if (segment.len == 0 or segment.len > segment_len_max) {
        return false;
    }

    for (segment, 0..) |char, index| lowered[index] = std.ascii.toLower(char);

    for (banned_abbreviations) |banned| {
        if (std.mem.eql(u8, lowered[0..segment.len], banned)) {
            return true;
        }
    }

    return false;
}

fn is_identifier_char(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '_';
}

fn declares_identifier(line: []const u8, start: u32, end: u32) bool {
    std.debug.assert(start < end);
    std.debug.assert(end <= line.len);

    const before = line[0..start];
    const after = line[end..];
    const declaring_words = [_][]const u8{ "const ", "var ", "|", "(", ", ", "comptime ", "fn " };
    const preceded = ends_with_any(before, &declaring_words) or only_spaces(before);
    const followed = starts_with_any(after, &.{ ":", " =", "|", ",", "(" });

    return preceded and followed;
}

fn only_spaces(text: []const u8) bool {
    std.debug.assert(text.len < file_bytes_max);

    for (text) |char| {
        if (char != ' ') {
            return false;
        }
    }

    std.debug.assert(text.len == 0 or text[0] == ' ');

    return true;
}

fn ends_with_any(text: []const u8, suffixes: []const []const u8) bool {
    std.debug.assert(suffixes.len > 0);

    for (suffixes) |suffix| {
        std.debug.assert(suffix.len > 0);
        if (std.mem.endsWith(u8, text, suffix)) {
            return true;
        }
    }

    return false;
}

fn starts_with_any(text: []const u8, prefixes: []const []const u8) bool {
    std.debug.assert(prefixes.len > 0);

    for (prefixes) |prefix| {
        std.debug.assert(prefix.len > 0);
        if (std.mem.startsWith(u8, text, prefix)) {
            return true;
        }
    }

    return false;
}

const usize_word = "u" ++ "size";
const typed_usize = ": " ++ usize_word;
const empty_catch = "catch {" ++ "}";

test "banned abbreviations are matched per segment, case-insensitively" {
    const short = "o" ++ "p";
    try std.testing.expect(has_banned_segment(short));
    try std.testing.expect(has_banned_segment("O" ++ "p"));
    try std.testing.expect(has_banned_segment(short ++ "_name"));
    try std.testing.expect(has_banned_segment("O" ++ "pId"));
    try std.testing.expect(has_banned_segment(short ++ "s_max"));
    try std.testing.expect(!has_banned_segment("operation"));
    try std.testing.expect(!has_banned_segment("operations"));
    try std.testing.expect(!has_banned_segment("options"));
    try std.testing.expect(!has_banned_segment("Ping"));
    try std.testing.expect(abbreviated_identifier("const " ++ short ++ " = 4;"));
    try std.testing.expect(abbreviated_identifier("    " ++ short ++ "_id: u64,"));
    try std.testing.expect(!abbreviated_identifier("    operation_id: u64,"));
    try std.testing.expect(!abbreviated_identifier("const operations = 6;"));
    try std.testing.expect(!abbreviated_identifier("pub fn find(operations: u32) void {"));
}
