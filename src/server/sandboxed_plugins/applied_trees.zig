//! The values of an apply (`applied.zig`) whose shape comes with the data: what the outer
//! edge sent as JSON and what core read from storage, held as values read where they lie.
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
const free_json = @import("../../sdk/free_json.zig");

const Over = applied.Over;
const laid_over = applied.laid_over;
const from_typed = applied.from_typed;
const fitting = applied.fitting;
const one = applied.one;
const Items = applied.Items;

/// A value whose shape comes with the data, as a piece holds one.
const Free = struct {
    bytes: []const u8,

    pub const publr_form = .free;
};

/// Values the outer edge sent as JSON, or that core read from storage: each a value whose
/// shape comes with the data.
pub fn from_trees(memory: std.mem.Allocator, items: []const std.json.Value) Error![]const u8 {
    const values = memory.alloc(Free, items.len) catch return error.OutOfMemory;

    std.debug.assert(items.len <= mods.items_max);

    for (items, values) |item, *value| {
        value.* = .{
            .bytes = (try free_json.from_tree(memory, item)).bytes,
        };
    }

    const text = comptime shape_wire.describe(Items(Free));
    const described = try described_module.parse(memory, text);
    var laid: laid_module.Laid = .{};
    var layout: Layout = .{
        .gpa = memory,
        .scratch = memory,
        .described = &described,
        .laid = &laid,
    };
    const list = described.fields_of(Described.root)[0];

    try layout.begin();

    const where = try layout.items(list.node, list.offset, values.len);
    const size = described.nodes[list.node].size;

    for (values, 0..) |value, index| {
        try layout.free(where + size * @as(u32, @intCast(index)), value.bytes);
    }

    return held_module.pieced(memory, text, &laid);
}

/// The values of `piece` as trees into `items`: as many as went, or `Invalid`.
pub fn to_trees(memory: std.mem.Allocator, piece: []const u8, items: []std.json.Value) Error!void {
    var opened: Opened = undefined;

    try opened.init(memory, piece);

    if (opened.items.count != items.len) {
        return error.Invalid;
    }

    std.debug.assert(items.len <= mods.items_max);

    for (items, 0..) |*item, index| {
        const source = opened.at(@intCast(index));

        if (opened.held.described.nodes[source.node].kind != .free) {
            return error.Invalid;
        }

        item.* = try free_json.tree_of(memory, .{
            .bytes = try source.given.free(source.bytes),
        });
    }
}

test "values whose shape comes with the data: a typed answer lies over them as JSON did" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = "[{\"name\":\"Tea\",\"price\":{\"PLN\":500},\"note\":\"kept\"}," ++
        "{\"name\":\"Cup\",\"price\":null},7]";
    const parsed = try std.json.parseFromSliceLeaky([]std.json.Value, arena, text, .{});
    const Priced = struct {
        name: []const u8,
        price: ?struct {
            PLN: i64,
        },
    };
    var standing: Opened = undefined;
    var answer: Opened = undefined;

    try standing.init(arena, try from_trees(arena, parsed));
    try answer.init(arena, try from_typed(Priced, arena, &.{
        .{
            .name = "Tea",
            .price = .{
                .PLN = 450,
            },
        },
        .{
            .name = "Mug",
            .price = .{
                .PLN = 900,
            },
        },
    }));

    const overs = [_]?Over{
        .{
            .answer = &answer,
            .index = 0,
        },
        .{
            .answer = &answer,
            .index = 1,
        },
        null,
    };

    try to_trees(arena, try laid_over(arena, &standing, &overs), parsed);
    try std.testing.expectEqualStrings(
        "[{\"name\":\"Tea\",\"price\":{\"PLN\":450},\"note\":\"kept\"}," ++
            "{\"name\":\"Mug\",\"price\":{\"PLN\":900}},7]",
        try std.json.Stringify.valueAlloc(arena, parsed, .{}),
    );

    // Only the values that read as a modifier's type are handed to it.
    const taken = try fitting(Priced, arena, &standing);

    try std.testing.expectEqual(@as(usize, 2), taken.values.len);
    try std.testing.expectEqual(@as(u32, 1), taken.places[1]);
    try std.testing.expectEqualStrings("Cup", taken.values[1].name);

    // One value alone is a piece of its own, in the same layout.
    var alone: Opened = undefined;

    try alone.init(arena, try one(arena, &standing, 2));
    try std.testing.expectEqual(@as(u32, 1), alone.items.count);
}
