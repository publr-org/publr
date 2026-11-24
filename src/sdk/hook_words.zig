//! A hook in its own words: a plugin hooking another's operation names only the fields it
//! uses (`publr.remote.operation`), so a compiled-in hook gets the operation's value read
//! into its type, as an installed one gets it through JSON, and what a `before` hook changed
//! laid back over the input, the fields it left out kept.
const std = @import("std");
const json_module = @import("../lib/json.zig");
const merged_tree = @import("../server/sandboxed_plugins/merged_tree.zig");

pub const Error = error{ OutOfMemory, Invalid };

/// `value` read into the hook's own type: fields it does not name are dropped.
pub fn own(comptime Own: type, arena: std.mem.Allocator, value: anytype) Error!Own {
    comptime std.debug.assert(@typeInfo(Own) == .@"struct");

    const text = std.json.Stringify.valueAlloc(arena, value, .{}) catch {
        return error.OutOfMemory;
    };

    std.debug.assert(text.len > 0);

    return json_module.parse(Own, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Invalid,
    };
}

/// `original` with what the hook wrote in its own words laid over it.
pub fn laid_over(
    comptime Value: type,
    arena: std.mem.Allocator,
    original: Value,
    written: anytype,
) Error!Value {
    comptime std.debug.assert(@typeInfo(Value) == .@"struct");

    var target = try value_of(arena, original);
    const changed = try value_of(arena, written);

    merged_tree.overlay(arena, &target, changed) catch return error.OutOfMemory;

    std.debug.assert(target != .null);

    return std.json.parseFromValueLeaky(Value, arena, target, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Invalid,
    };
}

fn value_of(arena: std.mem.Allocator, value: anytype) Error!std.json.Value {
    const text = std.json.Stringify.valueAlloc(arena, value, .{}) catch {
        return error.OutOfMemory;
    };

    std.debug.assert(text.len > 0);

    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Invalid,
    };
}

const Order = struct {
    id: []const u8,
    total: i64,
    note: []const u8 = "",
    lines: []const Line = &.{},

    const Line = struct {
        sku: []const u8,
        quantity: u32,
    };
};

const OwnOrder = struct {
    note: []const u8 = "",
};

test "a hook reads an operation in its own words and its change is laid over the rest" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const order: Order = .{
        .id = "o1",
        .total = 1200,
        .note = "ring twice",
        .lines = &.{.{
            .sku = "TEA",
            .quantity = 2,
        }},
    };

    var mine = try own(OwnOrder, arena, order);

    try std.testing.expectEqualStrings("ring twice", mine.note);

    mine.note = "leave at the door";

    const after = try laid_over(Order, arena, order, mine);

    try std.testing.expectEqualStrings("leave at the door", after.note);
    try std.testing.expectEqualStrings("o1", after.id);
    try std.testing.expectEqual(@as(i64, 1200), after.total);
    try std.testing.expectEqual(@as(u32, 2), after.lines[0].quantity);
}
