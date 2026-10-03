//! Amounts in minor units and the site's currencies: how one is written for people and
//! read back from what they type.

const std = @import("std");
const currency = @import("currency.zig");

/// A currency as the site shows it: `{ code: "GBP", symbol: "£", format: "{symbol}{amount}" }`,
/// or for euros in France `{ code: "EUR", symbol: "€", format: "{amount} {symbol}",
/// decimal: ",", thousands: " " }`. Only the code is needed.
pub const Entry = struct {
    code: []const u8,
    /// Empty: the code.
    symbol: []const u8 = "",
    /// `{symbol}`, `{amount}` and `{code}` are replaced; `{amount}` must be there.
    format: []const u8 = "{symbol}{amount}",
    decimal: []const u8 = ".",
    thousands: []const u8 = ",",
};

pub const symbol_len_max: u32 = 8;
pub const format_len_max: u32 = 32;
/// The separators an amount may be written with; anything else would read as another number.
pub const decimal_separators = [_][]const u8{ ".", "," };
pub const thousands_separators = [_][]const u8{ ",", ".", " ", "'", "" };

/// Why an entry cannot be a site currency, or null.
pub fn entry_problem(entry: Entry) ?[]const u8 {
    std.debug.assert(format_len_max > 0);

    if (currency.find(entry.code) == null) {
        return "a currency is an ISO 4217 code";
    }

    if (entry.symbol.len > symbol_len_max or entry.format.len > format_len_max) {
        return "a symbol is up to 8 bytes, a format up to 32";
    }

    if (std.mem.indexOf(u8, entry.format, "{amount}") == null) {
        return "a format holds {amount}";
    }

    if (!listed(&decimal_separators, entry.decimal)) {
        return "a decimal separator is . or ,";
    }

    if (!listed(&thousands_separators, entry.thousands)) {
        return "a thousands separator is , or . or ' or a space, or none";
    }

    if (std.mem.eql(u8, entry.decimal, entry.thousands)) {
        return "the decimal and thousands separators differ";
    }

    return null;
}

fn listed(choices: []const []const u8, separator: []const u8) bool {
    std.debug.assert(choices.len > 0);

    for (choices) |choice| {
        if (std.mem.eql(u8, choice, separator)) {
            return true;
        }
    }

    return false;
}

/// An amount in minor units as the entry writes it: 123456 GBP is `£1,234.56`.
pub fn format(buffer: []u8, amount: i64, entry: Entry) []const u8 {
    std.debug.assert(buffer.len >= 64);
    std.debug.assert(entry.code.len > 0);

    const digits: u8 = if (currency.find(entry.code)) |found| found.digits else 2;
    var number_buffer: [48]u8 = undefined;
    const magnitude: i64 = @intCast(@abs(amount));
    const number = grouped(&number_buffer, magnitude, digits, entry);
    const symbol = if (entry.symbol.len == 0) entry.code else entry.symbol;
    var writer = std.Io.Writer.fixed(buffer);
    var rest = entry.format;

    if (amount < 0) {
        writer.writeByte('-') catch return buffer[0..0];
    }

    while (rest.len > 0) {
        const placeholders = [_][2][]const u8{
            .{ "{symbol}", symbol },
            .{ "{amount}", number },
            .{ "{code}", entry.code },
        };
        var replaced = false;

        for (placeholders) |placeholder| {
            if (std.mem.startsWith(u8, rest, placeholder[0])) {
                writer.writeAll(placeholder[1]) catch return buffer[0..writer.end];
                rest = rest[placeholder[0].len..];
                replaced = true;
                break;
            }
        }

        if (!replaced) {
            writer.writeByte(rest[0]) catch return buffer[0..writer.end];
            rest = rest[1..];
        }
    }

    return buffer[0..writer.end];
}

/// A positive amount's digits with the entry's separators: `1,234.56`, `1 234,56`.
fn grouped(buffer: *[48]u8, amount: i64, digits: u8, entry: Entry) []const u8 {
    std.debug.assert(digits <= 4);

    std.debug.assert(amount >= 0);

    var plain_buffer: [32]u8 = undefined;
    const unsigned = format_minor(&plain_buffer, amount, digits);
    const dot = std.mem.indexOfScalar(u8, unsigned, '.') orelse unsigned.len;
    var writer = std.Io.Writer.fixed(buffer);

    for (unsigned[0..dot], 0..) |char, index| {
        const left = dot - index;

        if (index > 0 and left % 3 == 0) {
            writer.writeAll(entry.thousands) catch return buffer[0..writer.end];
        }

        writer.writeByte(char) catch return buffer[0..writer.end];
    }

    if (dot < unsigned.len) {
        writer.writeAll(entry.decimal) catch return buffer[0..writer.end];
        writer.writeAll(unsigned[dot + 1 ..]) catch return buffer[0..writer.end];
    }

    return buffer[0..writer.end];
}

/// An amount in minor units as people write it: 850 with 2 digits is `8.50`, 850 with 0 is
/// `850`, -5 with 2 is `-0.05`.
pub fn format_minor(buffer: []u8, amount: i64, digits: u8) []const u8 {
    std.debug.assert(buffer.len >= 32);
    std.debug.assert(digits <= 4);

    const scale = std.math.powi(u64, 10, digits) catch unreachable;
    const magnitude = @abs(amount);
    const sign: []const u8 = if (amount < 0) "-" else "";
    const whole = magnitude / scale;
    const fraction = magnitude % scale;
    const written = if (digits == 0)
        std.fmt.bufPrint(buffer, "{s}{d}", .{ sign, whole })
    else
        std.fmt.bufPrint(buffer, "{s}{d}.{d:0>[3]}", .{ sign, whole, fraction, digits });

    return written catch buffer[0..0];
}

/// An amount people wrote (`8.5`, `8.50`, `850`) in minor units, or null when it is not a
/// number or has more decimals than the currency.
pub fn parse_decimal(text: []const u8, digits: u8) ?i64 {
    std.debug.assert(digits <= 4);

    const trimmed = std.mem.trim(u8, text, " ");

    if (trimmed.len == 0 or trimmed.len > 24) {
        return null;
    }

    const negative = trimmed[0] == '-';
    const unsigned = if (negative) trimmed[1..] else trimmed;
    const dot = std.mem.indexOfScalar(u8, unsigned, '.');
    const whole_text = if (dot) |at| unsigned[0..at] else unsigned;
    const fraction_text = if (dot) |at| unsigned[at + 1 ..] else "";

    if (fraction_text.len > digits or (whole_text.len == 0 and fraction_text.len == 0)) {
        return null;
    }

    const whole = number_of(whole_text) orelse return null;
    var fraction = number_of(fraction_text) orelse return null;

    for (fraction_text.len..digits) |_| {
        fraction *= 10;
    }

    const scale = std.math.powi(i64, 10, digits) catch unreachable;
    const scaled = std.math.mul(i64, whole, scale) catch return null;
    const amount = std.math.add(i64, scaled, fraction) catch return null;

    return if (negative) -amount else amount;
}

/// Digits as a number; empty is 0.
fn number_of(text: []const u8) ?i64 {
    std.debug.assert(text.len <= 24);

    if (text.len == 0) {
        return 0;
    }

    return std.fmt.parseInt(i64, text, 10) catch null;
}

test "amounts: written and read back by the currency's digits" {
    var buffer: [32]u8 = undefined;

    try std.testing.expectEqualStrings("8.50", format_minor(&buffer, 850, 2));
    try std.testing.expectEqualStrings("850", format_minor(&buffer, 850, 0));
    try std.testing.expectEqualStrings("-0.05", format_minor(&buffer, -5, 2));
    try std.testing.expectEqualStrings("1.234", format_minor(&buffer, 1234, 3));
    try std.testing.expectEqual(@as(?i64, 850), parse_decimal("8.5", 2));
    try std.testing.expectEqual(@as(?i64, 850), parse_decimal("8.50", 2));
    try std.testing.expectEqual(@as(?i64, 800), parse_decimal("8", 2));
    try std.testing.expectEqual(@as(?i64, -5), parse_decimal("-0.05", 2));
    try std.testing.expect(parse_decimal("8.505", 2) == null);
    try std.testing.expect(parse_decimal("eight", 2) == null);
    try std.testing.expect(parse_decimal("", 2) == null);
}

test "entries: the site's symbol, format and separators" {
    var buffer: [64]u8 = undefined;
    const pound: Entry = .{ .code = "GBP", .symbol = "£" };
    const euro: Entry = .{
        .code = "EUR",
        .symbol = "€",
        .format = "{amount} {symbol}",
        .decimal = ",",
        .thousands = " ",
    };

    try std.testing.expectEqualStrings("£9.25", format(&buffer, 925, pound));
    try std.testing.expectEqualStrings("£1,234.56", format(&buffer, 123456, pound));
    try std.testing.expectEqualStrings("1 234,56 €", format(&buffer, 123456, euro));
    try std.testing.expectEqualStrings("JPY1,500", format(&buffer, 1500, .{ .code = "JPY" }));
    try std.testing.expectEqualStrings(
        "9.25 GBP",
        format(&buffer, 925, .{ .code = "GBP", .format = "{amount} {code}" }),
    );
    try std.testing.expectEqualStrings("-£0.05", format(&buffer, -5, pound));
    try std.testing.expect(entry_problem(pound) == null);
    try std.testing.expect(entry_problem(.{ .code = "GBP", .format = "{symbol}" }) != null);
    try std.testing.expect(entry_problem(.{ .code = "ZZZ" }) != null);
    try std.testing.expect(entry_problem(.{ .code = "GBP", .decimal = ";" }) != null);
    const same: Entry = .{ .code = "GBP", .thousands = ".", .decimal = "." };
    try std.testing.expect(entry_problem(same) != null);
    try std.testing.expect(entry_problem(euro) == null);
}
