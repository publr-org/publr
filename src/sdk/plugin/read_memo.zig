//! What one call of an installed plugin read already: inside one call no one else writes,
//! so the same read asked again answers the same until the plugin writes, and is answered
//! from here instead of crossing the wire again. A call that may write forgets all of it.
const std = @import("std");
const id_map = @import("../../publr/plugin/id_map.zig");

/// How many answers one call keeps; past it, reads go to the host as before.
pub const entries_max: u32 = 512;

pub const Memo = struct {
    entries: std.ArrayList(Entry) = .empty,
    /// Where the list of entries itself is kept: the operation's own memory, so that it
    /// outlives a scope a read was made in.
    home: ?std.mem.Allocator = null,

    const Entry = struct {
        hash: u64,
        name: []const u8,
        input: []const u8,
        shape: []const u8,
        value: *const anyopaque,
        /// The memory the answer is in: the allocator it was kept with.
        memory: *const anyopaque,
    };

    /// The answer `name` gave `input` earlier in this call, as an `Out`; null for none.
    pub fn find(
        memo: *const Memo,
        comptime Out: type,
        name: []const u8,
        input: []const u8,
    ) ?Out {
        std.debug.assert(name.len > 0);
        std.debug.assert(memo.entries.items.len <= entries_max);

        const hash = hash_of(name, input);

        for (memo.entries.items) |entry| {
            const same = entry.hash == hash and std.mem.eql(u8, entry.name, name) and
                std.mem.eql(u8, entry.input, input) and
                std.mem.eql(u8, entry.shape, @typeName(Out));

            if (same) {
                const value: *const Out = @ptrCast(@alignCast(entry.value));

                return value.*;
            }
        }

        return null;
    }

    /// Keeps `value` as what `name` answers `input` for the rest of the call.
    pub fn keep(
        memo: *Memo,
        arena: std.mem.Allocator,
        comptime Out: type,
        name: []const u8,
        input: []const u8,
        value: Out,
    ) error{OutOfMemory}!void {
        std.debug.assert(name.len > 0);
        std.debug.assert(memo.entries.items.len <= entries_max);

        if (memo.entries.items.len == entries_max) {
            return;
        }

        const held = try arena.create(Out);

        held.* = value;
        try memo.entries.append(memo.home orelse arena, .{
            .hash = hash_of(name, input),
            .name = name,
            .input = input,
            .shape = @typeName(Out),
            .value = held,
            .memory = arena.ptr,
        });
    }

    fn hash_of(name: []const u8, input: []const u8) u64 {
        std.debug.assert(name.len > 0);

        // 64-bit steps only: an installed plugin's machine does 128-bit ones in software.
        return id_map.hash_of(name) ^ (id_map.hash_of(input) *% 0x9E3779B97F4A7C15);
    }

    /// Forgets the answers kept with `memory` (an allocator's `ptr`): it is about to be
    /// given back. The others stay, in the order they were kept.
    pub fn drop(memo: *Memo, memory: *const anyopaque) void {
        std.debug.assert(memo.entries.items.len <= entries_max);

        var kept: u32 = 0;

        for (memo.entries.items) |entry| {
            if (entry.memory == memory) {
                continue;
            }

            memo.entries.items[kept] = entry;
            kept += 1;
        }

        std.debug.assert(kept <= memo.entries.items.len);

        memo.entries.items.len = kept;
    }

    /// Forgets every answer: something may have been written.
    pub fn forget(memo: *Memo) void {
        std.debug.assert(memo.entries.items.len <= entries_max);

        memo.entries.items.len = 0;

        std.debug.assert(memo.entries.items.len == 0);
    }
};

test "a read asked again is answered from the memo, until something may have written" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Out = struct {
        count: u32,
    };
    var memo: Memo = .{};

    try std.testing.expect(memo.find(Out, "internal.get", "{\"id\":\"a\"}") == null);
    try memo.keep(arena, Out, "internal.get", "{\"id\":\"a\"}", .{
        .count = 3,
    });

    const found = memo.find(Out, "internal.get", "{\"id\":\"a\"}").?;

    try std.testing.expectEqual(@as(u32, 3), found.count);
    try std.testing.expect(memo.find(Out, "internal.get", "{\"id\":\"b\"}") == null);
    try std.testing.expect(memo.find(u32, "internal.get", "{\"id\":\"a\"}") == null);

    memo.forget();

    try std.testing.expect(memo.find(Out, "internal.get", "{\"id\":\"a\"}") == null);
}

test "answers kept in a step's memory are dropped with it, whatever was kept around them" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var step_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    const step = step_state.allocator();
    var other_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer other_state.deinit();
    const other = other_state.allocator();
    var memo: Memo = .{
        .home = arena,
    };

    try memo.keep(arena, u32, "internal.get", "a", 1);
    try memo.keep(step, u32, "internal.get", "b", 2);
    try memo.keep(other, u32, "internal.get", "c", 3);
    try memo.keep(step, u32, "internal.get", "d", 4);
    try memo.keep(arena, u32, "internal.get", "e", 5);

    // The list itself is at home: the step's memory goes and the other answers stay.
    memo.drop(step.ptr);
    step_state.deinit();

    try std.testing.expectEqual(@as(?u32, 1), memo.find(u32, "internal.get", "a"));
    try std.testing.expectEqual(@as(?u32, null), memo.find(u32, "internal.get", "b"));
    try std.testing.expectEqual(@as(?u32, 3), memo.find(u32, "internal.get", "c"));
    try std.testing.expectEqual(@as(?u32, null), memo.find(u32, "internal.get", "d"));
    try std.testing.expectEqual(@as(?u32, 5), memo.find(u32, "internal.get", "e"));
    try std.testing.expectEqual(@as(usize, 3), memo.entries.items.len);

    // Dropped again, or after everything was forgotten: nothing left to drop.
    memo.drop(step.ptr);
    try std.testing.expectEqual(@as(usize, 3), memo.entries.items.len);

    memo.forget();
    memo.drop(other.ptr);
    try std.testing.expectEqual(@as(usize, 0), memo.entries.items.len);
}
