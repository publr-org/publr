//! `publr.IdMap(V)`: a map keyed by text that is mostly ids (a record's, an account's, a
//! currency's code). The standard text map hashes with 128-bit multiplies, which an
//! installed plugin's 32-bit machine does in software, several times a key: a tenth of a
//! request spent on it was measured. This one mixes eight bytes at a time in 64 bits, with
//! the same methods as `std.StringHashMapUnmanaged`.
const std = @import("std");

/// A map from text to `Value` with the standard map's methods, each taking its allocator:
/// core's own (`publr.IdMap` is a plugin's, `collections.zig`). Keys are not copied.
pub fn Map(comptime Value: type) type {
    return std.HashMapUnmanaged(
        []const u8,
        Value,
        Context,
        std.hash_map.default_max_load_percentage,
    );
}

/// `Map` that keeps its keys in the order they were put: `keys()` and `values()` are in
/// that order.
pub fn OrderedMap(comptime Value: type) type {
    return std.ArrayHashMapUnmanaged([]const u8, Value, ListContext, true);
}

pub const Context = struct {
    pub fn hash(_: Context, key: []const u8) u64 {
        return hash_of(key);
    }

    pub fn eql(_: Context, left: []const u8, right: []const u8) bool {
        return same(left, right);
    }
};

pub const ListContext = struct {
    pub fn hash(_: ListContext, key: []const u8) u32 {
        return @truncate(hash_of(key));
    }

    pub fn eql(_: ListContext, left: []const u8, right: []const u8, _: anytype) bool {
        return same(left, right);
    }
};

/// Whether two texts are the same. Ids made close in time start alike, so the ends are
/// compared first: two different ids are told apart in one step.
pub fn same(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) {
        return false;
    }

    std.debug.assert(left.len == right.len);

    if (left.len >= 8) {
        const tail = left.len - 8;
        const left_end = std.mem.readInt(u64, left[tail..][0..8], .little);
        const right_end = std.mem.readInt(u64, right[tail..][0..8], .little);

        if (left_end != right_end) {
            return false;
        }
    }

    return std.mem.eql(u8, left, right);
}

/// A text's hash, 64 bits wide, from 64-bit steps only: eight bytes at a time, each mixed in
/// with one multiply. Not for anything an attacker may choose keys against at scale: a map
/// in a plugin lives for one call, within its limits.
pub fn hash_of(key: []const u8) u64 {
    const prime: u64 = 0x9E3779B97F4A7C15;
    var mixed: u64 = prime ^ key.len;
    var rest = key;

    std.debug.assert(key.len <= std.math.maxInt(u32));

    while (rest.len >= 8) : (rest = rest[8..]) {
        mixed = (mixed ^ std.mem.readInt(u64, rest[0..8], .little)) *% prime;
        mixed ^= mixed >> 29;
    }

    var tail: u64 = 0;

    for (rest, 0..) |byte, index| {
        tail |= @as(u64, byte) << @intCast(index * 8);
    }

    mixed = (mixed ^ tail) *% prime;
    mixed ^= mixed >> 32;
    mixed *%= 0xD6E8FEB86659FD93;
    mixed ^= mixed >> 32;

    return mixed;
}

test "ids made one after the other spread over a map's slots and its marks" {
    var low: [64]u32 = @splat(0);
    var high: [128]u32 = @splat(0);
    var buffer: [24]u8 = undefined;

    for (0..6400) |index| {
        const id = try std.fmt.bufPrint(&buffer, "01a2b3c4d5e6f7{x:0>10}", .{index});
        const mixed = hash_of(id);

        low[mixed & 63] += 1;
        high[mixed >> 57] += 1;
    }

    // 100 a slot and 50 a mark when even: none is empty, none takes several times its share.
    for (low) |count| {
        try std.testing.expect(count > 50 and count < 200);
    }

    for (high) |count| {
        try std.testing.expect(count > 20 and count < 100);
    }
}

test "a map by id keeps what it is given; a list of them keeps their order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var prices: Map(u32) = .empty;
    var order: OrderedMap(u32) = .empty;

    const keys = [_][]const u8{ "0190c8a3d2e1000014f2a6b9", "0190c8a3d2e1000014f2a6ba", "PLN", "" };

    for (keys, 0..) |id, at| {
        try prices.put(arena, id, @intCast(at));
        try order.put(arena, id, @intCast(at));
    }

    try std.testing.expectEqual(@as(?u32, 1), prices.get("0190c8a3d2e1000014f2a6ba"));
    try std.testing.expectEqual(@as(?u32, 2), prices.get("PLN"));
    try std.testing.expectEqual(@as(?u32, 3), prices.get(""));
    try std.testing.expectEqual(@as(?u32, null), prices.get("0190c8a3d2e1000014f2a6bb"));
    try std.testing.expectEqual(@as(?u32, null), prices.get("PLn"));
    try std.testing.expectEqualStrings("PLN", order.keys()[2]);
    try std.testing.expect(same("abc", "abc") and !same("abc", "abd") and !same("ab", "abc"));
}
