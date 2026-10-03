//! The bounds an operation declares on its input's fields, in the words content fields use:
//! a number's range, a text's length and shape, a list's size. Core checks them before the
//! operation runs, so the operation never writes them by hand.

const std = @import("std");
const options = @import("field/options.zig");
const pattern = @import("field/pattern.zig");

pub const Preset = options.Preset;

pub const Rule = struct {
    /// A number's bounds, inclusive.
    min: ?i64 = null,
    max: ?i64 = null,
    /// A text's length in characters, inclusive.
    min_len: ?u32 = null,
    max_len: ?u32 = null,
    /// A list's size, inclusive.
    items_min: ?u32 = null,
    items_max: ?u32 = null,
    /// A shape a text must have: a preset, or a pattern of `*` `?` `#` `@`.
    preset: Preset = .any,
    pattern: []const u8 = "",

    pub fn empty(rule: Rule) bool {
        std.debug.assert(rule.pattern.len <= options.pattern_len_max);

        return rule.min == null and rule.max == null and rule.min_len == null and
            rule.max_len == null and rule.items_min == null and rule.items_max == null and
            rule.preset == .any and rule.pattern.len == 0;
    }
};

/// What a value breaks of its rule, in words (`must be from 1 to 20`), or null. A value of
/// another kind than the rule speaks of breaks nothing here: its type is checked apart.
pub fn broken(rule: Rule, value: std.json.Value) ?[]const u8 {
    std.debug.assert(rule.pattern.len <= options.pattern_len_max);

    return switch (value) {
        .integer => |number| number_broken(rule, number),
        .float => |number| number_broken(rule, @intFromFloat(@trunc(number))),
        .string => |text| text_broken(rule, text),
        .array => |list| list_broken(rule, @intCast(list.items.len)),
        else => null,
    };
}

fn number_broken(rule: Rule, number: i64) ?[]const u8 {
    std.debug.assert(options.ordered(i64, rule.min, rule.max));

    if (rule.min) |low| {
        if (number < low) {
            return "is below its least value";
        }
    }

    if (rule.max) |high| {
        if (number > high) {
            return "is above its greatest value";
        }
    }

    return null;
}

fn text_broken(rule: Rule, text: []const u8) ?[]const u8 {
    std.debug.assert(options.ordered(u32, rule.min_len, rule.max_len));

    const length: u32 = @intCast(std.unicode.utf8CountCodepoints(text) catch text.len);

    if (rule.min_len) |low| {
        if (length < low) {
            return "is shorter than it may be";
        }
    }

    if (rule.max_len) |high| {
        if (length > high) {
            return "is longer than it may be";
        }
    }

    if (!pattern.matches_preset(rule.preset, text)) {
        return "does not have the shape it must";
    }

    if (rule.pattern.len > 0 and !pattern.matches(rule.pattern, text)) {
        return "does not match its pattern";
    }

    return null;
}

fn list_broken(rule: Rule, size: u32) ?[]const u8 {
    std.debug.assert(options.ordered(u32, rule.items_min, rule.items_max));

    if (rule.items_min) |low| {
        if (size < low) {
            return "has fewer items than it must";
        }
    }

    if (rule.items_max) |high| {
        if (size > high) {
            return "has more items than it may";
        }
    }

    return null;
}

test "rules: numbers, texts and lists, each held to its own" {
    const quantity: Rule = .{ .min = 1, .max = 20 };
    const code: Rule = .{ .min_len = 2, .max_len = 4, .preset = .uppercase };
    const lines: Rule = .{ .items_min = 1, .items_max = 2 };

    try std.testing.expect(broken(quantity, .{ .integer = 5 }) == null);
    try std.testing.expect(broken(quantity, .{ .integer = 0 }) != null);
    try std.testing.expect(broken(quantity, .{ .integer = 21 }) != null);
    try std.testing.expect(broken(code, .{ .string = "ABC" }) == null);
    try std.testing.expect(broken(code, .{ .string = "A" }) != null);
    try std.testing.expect(broken(code, .{ .string = "abc" }) != null);
    try std.testing.expect(broken(lines, .{ .array = .init(std.testing.allocator) }) != null);
    try std.testing.expect((Rule{}).empty());
    try std.testing.expect(!quantity.empty());
}
