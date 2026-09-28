//! The shape a text must have: a preset (digits, letters, a phone number), or a pattern
//! where `*` matches any run, `?` one character, `#` one digit and `@` one letter.
//! Everything else in a pattern matches itself. Small on purpose: no regular
//! expressions, nothing an editor cannot read back.
const std = @import("std");
const options = @import("options.zig");

const Preset = options.Preset;

pub const text_len_max: u32 = 64 << 10;

pub fn matches_preset(preset: Preset, text: []const u8) bool {
    std.debug.assert(text.len <= text_len_max);
    std.debug.assert(@intFromEnum(preset) <= 7);

    if (preset == .any) {
        return true;
    }

    if (text.len == 0) {
        return preset != .phone;
    }

    if (preset == .phone) {
        return is_phone(text);
    }

    for (text) |char| {
        const ok = switch (preset) {
            .digits => is_digit(char),
            .letters => is_letter(char),
            .alphanumeric => is_digit(char) or is_letter(char),
            .no_spaces => !std.ascii.isWhitespace(char),
            .lowercase => !std.ascii.isUpper(char),
            .uppercase => !std.ascii.isLower(char),
            .any, .phone => unreachable,
        };

        if (!ok) {
            return false;
        }
    }

    return true;
}

/// Digits, spaces, dashes, dots and parentheses, an optional leading `+`, at least six
/// digits in all.
fn is_phone(text: []const u8) bool {
    std.debug.assert(text.len > 0);
    std.debug.assert(text.len <= text_len_max);

    var digits: u32 = 0;

    for (text, 0..) |char, index| {
        if (is_digit(char)) {
            digits += 1;
        } else if (char == '+') {
            if (index != 0) {
                return false;
            }
        } else if (!(char == ' ' or char == '-' or char == '.' or char == '(' or char == ')')) {
            return false;
        }
    }

    return digits >= 6;
}

/// Whether `text` fits `pattern` whole. `*` backtracks the classic way: one star kept
/// at a time is enough, since a later star restarts the search from its own place.
pub fn matches(pattern: []const u8, text: []const u8) bool {
    std.debug.assert(pattern.len <= options.pattern_len_max);
    std.debug.assert(text.len <= text_len_max);

    if (pattern.len == 0) {
        return true;
    }

    var pattern_index: usize = 0;
    var text_index: usize = 0;
    var star_pattern: ?usize = null;
    var star_text: usize = 0;

    while (text_index < text.len) {
        if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star_pattern = pattern_index;
            star_text = text_index;
            pattern_index += 1;
        } else if (pattern_index < pattern.len and
            one_matches(pattern[pattern_index], text[text_index]))
        {
            pattern_index += 1;
            text_index += 1;
        } else if (star_pattern) |star| {
            pattern_index = star + 1;
            star_text += 1;
            text_index = star_text;
        } else {
            return false;
        }
    }

    while (pattern_index < pattern.len and pattern[pattern_index] == '*') {
        pattern_index += 1;
    }

    return pattern_index == pattern.len;
}

fn one_matches(wanted: u8, char: u8) bool {
    std.debug.assert(wanted != '*');
    std.debug.assert(text_len_max > 0);

    return switch (wanted) {
        '?' => true,
        '#' => is_digit(char),
        '@' => is_letter(char),
        else => wanted == char,
    };
}

fn is_digit(char: u8) bool {
    return char >= '0' and char <= '9';
}

fn is_letter(char: u8) bool {
    return (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z');
}

/// How many words a text holds: runs of anything but whitespace.
pub fn word_count(text: []const u8) u32 {
    std.debug.assert(text.len <= text_len_max);
    std.debug.assert(text_len_max > 0);

    var words: u32 = 0;
    var in_word = false;

    for (text) |char| {
        const space = std.ascii.isWhitespace(char);

        if (!space and !in_word) {
            words += 1;
        }

        in_word = !space;
    }

    return words;
}

test "presets" {
    try std.testing.expect(matches_preset(.any, "anything at all"));
    try std.testing.expect(matches_preset(.digits, "0123"));
    try std.testing.expect(!matches_preset(.digits, "12a"));
    try std.testing.expect(matches_preset(.letters, "abcXYZ"));
    try std.testing.expect(!matches_preset(.letters, "ab1"));
    try std.testing.expect(matches_preset(.alphanumeric, "ab1"));
    try std.testing.expect(!matches_preset(.alphanumeric, "ab 1"));
    try std.testing.expect(matches_preset(.no_spaces, "a-b_c"));
    try std.testing.expect(!matches_preset(.no_spaces, "a b"));
    try std.testing.expect(matches_preset(.lowercase, "abc-1"));
    try std.testing.expect(!matches_preset(.lowercase, "Abc"));
    try std.testing.expect(matches_preset(.uppercase, "ABC 1"));
    try std.testing.expect(!matches_preset(.uppercase, "ABc"));
    try std.testing.expect(matches_preset(.phone, "+48 (12) 345-67-89"));
    try std.testing.expect(!matches_preset(.phone, "12+34"));
    try std.testing.expect(!matches_preset(.phone, "123"));
    try std.testing.expect(!matches_preset(.phone, ""));
    try std.testing.expect(matches_preset(.digits, ""));
}

test "patterns" {
    try std.testing.expect(matches("", "anything"));
    try std.testing.expect(matches("SKU-####", "SKU-1234"));
    try std.testing.expect(!matches("SKU-####", "SKU-12345"));
    try std.testing.expect(!matches("SKU-####", "SKU-12a4"));
    try std.testing.expect(matches("@@-*", "AB-anything here"));
    try std.testing.expect(!matches("@@-*", "A1-x"));
    try std.testing.expect(matches("*.pdf", "report.final.pdf"));
    try std.testing.expect(!matches("*.pdf", "report.pdf.bak"));
    try std.testing.expect(matches("a*b*c", "aXXbYYc"));
    try std.testing.expect(!matches("a*b*c", "aXXcYYb"));
    try std.testing.expect(matches("?", "x"));
    try std.testing.expect(!matches("?", ""));
    try std.testing.expect(matches("*", ""));
    try std.testing.expect(matches("**x", "x"));
}

test "word counts" {
    try std.testing.expectEqual(@as(u32, 0), word_count(""));
    try std.testing.expectEqual(@as(u32, 0), word_count("   \n"));
    try std.testing.expectEqual(@as(u32, 3), word_count("one  two\nthree "));
    try std.testing.expectEqual(@as(u32, 1), word_count("hyphen-ated"));
}
