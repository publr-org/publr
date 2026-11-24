//! What drawing one page keeps for the rest of it: a component's script heap with its
//! program loaded (`ui/scripted.zig`), used again by the next component of the same program
//! instead of started anew. Let go when the page is drawn.
const std = @import("std");

pub const items_max: u32 = 64;

pub const Held = struct {
    items: std.ArrayList(Item) = .empty,

    pub const Item = struct {
        key: *const anyopaque,
        value: *anyopaque,
        release: *const fn (value: *anyopaque) void,
    };

    /// What was kept for `key`, or null.
    pub fn find(held: *const Held, key: *const anyopaque) ?*anyopaque {
        std.debug.assert(held.items.items.len <= items_max);

        for (held.items.items) |item| {
            if (item.key == key) {
                return item.value;
            }
        }

        return null;
    }

    /// Keeps `item` until `release`; false when the page already keeps as many as it may,
    /// and the caller lets the value go itself.
    pub fn keep(held: *Held, arena: std.mem.Allocator, item: Item) !bool {
        std.debug.assert(held.find(item.key) == null);

        if (held.items.items.len == items_max) {
            return false;
        }

        try held.items.append(arena, item);
        return true;
    }

    pub fn release(held: *Held) void {
        std.debug.assert(held.items.items.len <= items_max);

        for (held.items.items) |item| {
            item.release(item.value);
        }

        held.items.clearRetainingCapacity();
    }
};

fn count_release(value: *anyopaque) void {
    const count: *u32 = @ptrCast(@alignCast(value));

    count.* += 1;
}

test "a kept value is found by its key and let go once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var held: Held = .{};
    var released: u32 = 0;
    const key: u32 = 7;
    const other: u32 = 8;

    try std.testing.expect(try held.keep(arena_state.allocator(), .{
        .key = &key,
        .value = &released,
        .release = &count_release,
    }));
    try std.testing.expect(held.find(&key) != null);
    try std.testing.expect(held.find(&other) == null);

    held.release();
    held.release();

    try std.testing.expectEqual(@as(u32, 1), released);
}
