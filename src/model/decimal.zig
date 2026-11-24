//! An exact decimal number written as text (`1.25`): a whole number of units of its last
//! place, never a binary fraction. What a `decimal` field holds and `publr.Decimal` reads.
const std = @import("std");

/// The most places a decimal may have: an `i64` of units still holds billions of units.
pub const places_max: u8 = 9;
pub const text_len_max: u32 = 24;

pub const Problem = error{ NotDecimal, TooManyPlaces, TooLarge };

/// `text` as units of `places` places: `1.25` at 3 places is 1250. Fewer places written
/// are filled with zeros; more are refused, never rounded.
pub fn units_of(text: []const u8, places: u8) Problem!i64 {
    std.debug.assert(places <= places_max);

    if (text.len == 0 or text.len > text_len_max) {
        return if (text.len == 0) error.NotDecimal else error.TooLarge;
    }

    const negative = text[0] == '-';
    const digits = if (negative) text[1..] else text;
    const dot = std.mem.indexOfScalar(u8, digits, '.');
    const whole = digits[0 .. dot orelse digits.len];
    const fraction = if (dot) |at| digits[at + 1 ..] else "";

    if (whole.len == 0 or (dot != null and fraction.len == 0)) {
        return error.NotDecimal;
    }

    if (fraction.len > places) {
        return error.TooManyPlaces;
    }

    var units: i64 = 0;

    for ([_][]const u8{ whole, fraction }) |part| {
        for (part) |char| {
            if (char < '0' or char > '9') {
                return error.NotDecimal;
            }

            units = std.math.mul(i64, units, 10) catch return error.TooLarge;
            units = std.math.add(i64, units, char - '0') catch return error.TooLarge;
        }
    }

    for (fraction.len..places) |_| {
        units = std.math.mul(i64, units, 10) catch return error.TooLarge;
    }

    return if (negative) -units else units;
}

/// `units` of `places` places written as text, every place shown: 1250 at 3 is `1.250`.
pub fn text_of(units: i64, places: u8, buffer: *[text_len_max]u8) []const u8 {
    std.debug.assert(places <= places_max);

    const scale = std.math.powi(i64, 10, places) catch unreachable;
    const magnitude = @abs(units);
    const whole = magnitude / @as(u64, @intCast(scale));
    const fraction = magnitude % @as(u64, @intCast(scale));
    const sign: []const u8 = if (units < 0) "-" else "";
    const head = std.fmt.bufPrint(buffer, "{s}{d}", .{ sign, whole }) catch unreachable;

    if (places == 0) {
        return head;
    }

    // The fraction with its leading zeros: every place shown.
    var at: u32 = @intCast(head.len + 1 + places);
    var left = fraction;

    buffer[head.len] = '.';

    for (0..places) |_| {
        at -= 1;
        buffer[at] = '0' + @as(u8, @intCast(left % 10));
        left /= 10;
    }

    return buffer[0 .. head.len + 1 + places];
}

test "a decimal is read as units of its places and written back with every place" {
    try std.testing.expectEqual(@as(i64, 1250), try units_of("1.25", 3));
    try std.testing.expectEqual(@as(i64, -500), try units_of("-0.5", 3));
    try std.testing.expectEqual(@as(i64, 7), try units_of("7", 0));
    try std.testing.expectError(error.TooManyPlaces, units_of("1.255", 2));
    try std.testing.expectError(error.NotDecimal, units_of("1.", 2));
    try std.testing.expectError(error.NotDecimal, units_of("1e3", 2));
    try std.testing.expectError(error.NotDecimal, units_of("", 2));
    try std.testing.expectError(error.TooLarge, units_of("99999999999999999999", 2));

    var buffer: [text_len_max]u8 = undefined;

    try std.testing.expectEqualStrings("1.250", text_of(1250, 3, &buffer));
    try std.testing.expectEqualStrings("-0.05", text_of(-5, 2, &buffer));
    try std.testing.expectEqualStrings("12", text_of(12, 0, &buffer));
}
