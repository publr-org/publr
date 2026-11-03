//! What of a record goes live: every combination of the site's dimensions but the ones it
//! holds back. A record keeps the held back ones (`held_back`), each a combination as a key
//! names it, joined by `;`: `language=pl;language=de,variation=b`. A value the site adds
//! later thus goes live. Held back where the dimension has pages of its own (Polish at
//! `/pl`), the record is not there; held back where a visitor is given a value (a variation),
//! they read the record as if every other dimension were at its main value.

const std = @import("std");
const dimension = @import("../dimension.zig");

const Pair = dimension.Pair;
const dimensions_max = dimension.dimensions_max;
pub const combination_len_max = dimension.combination_len_max;

pub const separator: u8 = ';';
/// The combinations one record holds back at most.
pub const held_max: u32 = 256;
pub const held_back_len_max: u32 = held_max * (combination_len_max + 1);

/// Whether `held_back` holds `combination` back. The main values always go live.
pub fn held(held_back: []const u8, combination: []const u8) bool {
    std.debug.assert(held_back.len <= held_back_len_max);

    if (combination.len == 0) {
        return false;
    }

    var parts = std.mem.splitScalar(u8, held_back, separator);

    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, combination)) {
            return true;
        }
    }

    return false;
}

/// `pairs` as a key names them (`language=pl,variation=b`): the main values left out, the
/// rest sorted. Null when it names more than `key_pairs_max` dimensions.
pub fn combination_of(buffer: *[combination_len_max + 2]u8, pairs: []const Pair) ?[]const u8 {
    std.debug.assert(pairs.len <= dimensions_max);

    const key = dimension.key_into(buffer, "x", pairs) orelse return null;

    return if (key.len == 1) "" else key[2..];
}

/// The combination a read in `wanted` gives, by what `held_back` holds back: null when the
/// record is held back at the address `wanted` is at (its `addressed` dimension's value);
/// `wanted` itself when it goes live; else `wanted` with every dimension but `addressed` at
/// its main value, written into `out`.
pub fn read_as(
    held_back: []const u8,
    wanted: []const Pair,
    addressed: []const u8,
    out: *[dimensions_max]Pair,
) ?[]const Pair {
    std.debug.assert(wanted.len <= dimensions_max);
    std.debug.assert(held_back.len <= held_back_len_max);

    if (held_back.len == 0) {
        return wanted;
    }

    for (wanted, 0..) |pair, index| {
        const kept = addressed.len > 0 and std.mem.eql(u8, pair.dimension, addressed);

        out[index] = .{
            .dimension = pair.dimension,
            .code = if (kept) pair.code else "",
        };
    }

    const narrowed = out[0..wanted.len];
    var buffer: [combination_len_max + 2]u8 = undefined;
    const address = combination_of(&buffer, narrowed) orelse return wanted;

    if (held(held_back, address)) {
        return null;
    }

    const asked = combination_of(&buffer, wanted) orelse return wanted;

    return if (held(held_back, asked)) narrowed else wanted;
}

/// `combinations` as a record keeps them: each one a key names, none twice, none the main
/// values; null when one is not.
pub fn joined(
    arena: std.mem.Allocator,
    combinations: []const []const u8,
) error{OutOfMemory}!?[]const u8 {
    std.debug.assert(held_max > 0);

    if (combinations.len > held_max) {
        return null;
    }

    for (combinations, 0..) |combination, index| {
        if (dimension.parse(combination) == null) {
            return null;
        }

        for (combinations[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier, combination)) {
                return null;
            }
        }
    }

    return try std.mem.join(arena, &.{separator}, combinations);
}

test "read_as: held back at its address, nothing; else the address's main values" {
    const polish_b = [_]Pair{
        .{
            .dimension = "language",
            .code = "pl",
        },
        .{
            .dimension = "variation",
            .code = "b",
        },
    };
    var out: [dimensions_max]Pair = undefined;

    try std.testing.expectEqual(@as(usize, 2), read_as("", &polish_b, "language", &out).?.len);

    const narrowed = read_as("language=pl,variation=b", &polish_b, "language", &out).?;

    try std.testing.expectEqualStrings("pl", narrowed[0].code);
    try std.testing.expectEqualStrings("", narrowed[1].code);
    // Polish held back: the record is not at `/pl`, whatever variation a visitor is given.
    try std.testing.expect(read_as("language=pl", &polish_b, "language", &out) == null);
    const german_held = read_as("language=de", &polish_b, "language", &out).?;

    try std.testing.expectEqualStrings("b", german_held[1].code);

    // No addressed dimension: the main values.
    const unaddressed = read_as("language=pl,variation=b", &polish_b, "", &out).?;

    try std.testing.expectEqualStrings("", unaddressed[0].code);
}

test "joined: combinations a key names, once each" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const held_back = (try joined(arena, &.{ "language=pl", "language=de,variation=b" })).?;

    try std.testing.expectEqualStrings("language=pl;language=de,variation=b", held_back);
    try std.testing.expect(held(held_back, "language=de,variation=b"));
    try std.testing.expect(!held(held_back, "language=de"));
    try std.testing.expect(!held(held_back, ""));
    try std.testing.expect(try joined(arena, &.{""}) == null);
    try std.testing.expect(try joined(arena, &.{ "language=pl", "language=pl" }) == null);
    try std.testing.expect(try joined(arena, &.{"variation=b,language=pl"}) == null);
}
