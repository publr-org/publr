//! The values of an apply (`applied.zig`) as a compiled-in modifier takes them: read into
//! its own structs, and what it left them as laid over the values like any answer.
const std = @import("std");
const mods = @import("../../sdk/mods.zig");
const shape_wire = @import("../../sdk/plugin/shape_wire.zig");
const described_module = @import("described.zig");
const given_typed = @import("given_typed.zig");
const laid_module = @import("laid.zig");
const held_module = @import("held.zig");
const applied = @import("applied.zig");
const merged = @import("merged.zig");
const transfer = @import("transfer.zig");

const Described = described_module.Described;
const Layout = laid_module.Layout;
const Opened = applied.Opened;
const Error = applied.Error;

const Over = applied.Over;
const laid_over = applied.laid_over;
const from_typed = applied.from_typed;
const to_typed = applied.to_typed;

/// The values of `opened` that read as a modifier's `Value`, and which each one is: one that
/// does not read as it is left out, to stay as it is.
pub fn Fitting(comptime Value: type) type {
    return struct {
        values: []Value,
        places: []u32,
    };
}

pub fn fitting(
    comptime Value: type,
    memory: std.mem.Allocator,
    opened: *Opened,
) Error!Fitting(Value) {
    const count = opened.items.count;
    const values = memory.alloc(Value, count) catch return error.OutOfMemory;
    const places = memory.alloc(u32, count) catch return error.OutOfMemory;
    var found: u32 = 0;

    std.debug.assert(count <= mods.items_max);

    for (0..count) |index| {
        const source = opened.at(@intCast(index));
        const next = opened.reading.next;

        values[found] = given_typed.read(Value, source.given, source.node, source.bytes, .{
            .ignore_unknown = true,
            .absent = .null,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Invalid => {
                // Its unions beside the block are stepped over as a whole.
                opened.reading.next = next;
                try opened.reading.skip(source.node, source.bytes);
                continue;
            },
        };
        places[found] = @intCast(index);
        found += 1;
    }

    opened.reading.next = 0;

    return .{
        .values = values[0..found],
        .places = places[0..found],
    };
}

/// What a compiled-in modifier left `taken` as, laid over the values of `standing` it took
/// them from: one piece in `memory`.
pub fn answered(
    comptime Value: type,
    memory: std.mem.Allocator,
    standing: *Opened,
    taken: Fitting(Value),
) Error![]const u8 {
    const count = standing.items.count;
    const overs = memory.alloc(?Over, count) catch return error.OutOfMemory;
    var answer: Opened = undefined;

    std.debug.assert(taken.values.len == taken.places.len);
    std.debug.assert(taken.values.len <= count);

    try answer.init(memory, try from_typed(Value, memory, taken.values));
    @memset(overs, null);

    for (taken.places, 0..) |place, index| {
        overs[place] = .{
            .answer = &answer,
            .index = @intCast(index),
        };
    }

    return laid_over(memory, standing, overs);
}

const test_laid = @import("applied_over.zig").test_laid;

test "an answer that cannot lie over its value leaves that value as it was, the others change" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Owned = struct {
        name: []const u8,
        count: u8,
    };
    const Wrong = struct {
        name: ?[]const u8,
        count: u32,
    };
    const owned = [_]Owned{
        .{
            .name = "first",
            .count = 1,
        },
        .{
            .name = "second",
            .count = 2,
        },
        .{
            .name = "third",
            .count = 3,
        },
    };
    const laid = try test_laid(Owned, Wrong, arena, &owned, &.{
        .{
            .name = "one",
            .count = 300,
        },
        .{
            .name = null,
            .count = 20,
        },
        .{
            .name = "three",
            .count = 30,
        },
    });

    // A number the value cannot hold, and nothing where it must hold a text.
    try std.testing.expectEqualStrings("first", laid[0].name);
    try std.testing.expectEqual(@as(u8, 1), laid[0].count);
    try std.testing.expectEqualStrings("second", laid[1].name);
    try std.testing.expectEqual(@as(u8, 2), laid[1].count);
    try std.testing.expectEqualStrings("three", laid[2].name);
    try std.testing.expectEqual(@as(u8, 30), laid[2].count);
}

test "a field only a modifier has is kept beside the value's own: the next modifier reads it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Owned = struct {
        id: []const u8,
        count: u8,
    };
    const First = struct {
        id: []const u8,
        grams: u64,
        ships: ?bool = null,
    };
    const Second = struct {
        id: []const u8,
        grams: u64 = 0,
        count: u8,
    };
    const owned = [_]Owned{
        .{
            .id = "a",
            .count = 1,
        },
        .{
            .id = "b",
            .count = 2,
        },
    };
    var standing: Opened = undefined;
    var answer: Opened = undefined;
    var after: Opened = undefined;

    try standing.init(arena, try from_typed(Owned, arena, &owned));
    try answer.init(arena, try from_typed(First, arena, &.{.{
        .id = "a",
        .grams = 120,
    }}));
    try after.init(arena, try laid_over(arena, &standing, &.{
        .{
            .answer = &answer,
            .index = 0,
        },
        null,
    }));

    // The second value was not answered: it has no grams, and reads at the default.
    const seen = try fitting(Second, arena, &after);

    try std.testing.expectEqual(@as(usize, 2), seen.values.len);
    try std.testing.expectEqual(@as(u64, 120), seen.values[0].grams);
    try std.testing.expectEqual(@as(u64, 0), seen.values[1].grams);
    try std.testing.expectEqual(@as(u8, 2), seen.values[1].count);

    seen.values[1].grams = 7;

    const last = try answered(Second, arena, &after, seen);
    const back = try to_typed(Owned, arena, last);
    const kept = try to_typed(Second, arena, last);

    try std.testing.expectEqualStrings("b", back[1].id);
    try std.testing.expectEqual(@as(u8, 2), back[1].count);
    try std.testing.expectEqual(@as(u64, 120), kept[0].grams);
    try std.testing.expectEqual(@as(u64, 7), kept[1].grams);
}
