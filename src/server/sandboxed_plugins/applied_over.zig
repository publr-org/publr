//! A modifier's answers laid over the values of an apply (`applied.zig`): one piece built
//! from the values as they stand and what was answered for each, in the values' own layout
//! with the fields only the modifier's type has added (`merged_shape.zig`).
const std = @import("std");
const mods = @import("../../sdk/mods.zig");
const shape_wire = @import("../../sdk/plugin/shape_wire.zig");
const described_module = @import("described.zig");
const laid_module = @import("laid.zig");
const held_module = @import("held.zig");
const applied = @import("applied.zig");
const merged = @import("merged.zig");
const transfer = @import("transfer.zig");

const Described = described_module.Described;
const Layout = laid_module.Layout;
const Opened = applied.Opened;
const Error = applied.Error;
const from_typed = applied.from_typed;
const to_typed = applied.to_typed;
const merged_shape = @import("merged_shape.zig");

/// What a modifier answered for one value: which value of which answer.
pub const Over = struct {
    answer: *Opened,
    index: u32,
};

/// The values of `standing`, each with what a modifier answered for it laid over
/// (`overs`, one for each value, null where it answered nothing): one piece in `memory`.
/// An answer that cannot lie over its value leaves that value as it was. The piece's
/// layout is the values' own, with the fields only the modifier's type has added.
pub fn laid_over(
    memory: std.mem.Allocator,
    standing: *Opened,
    overs: []const ?Over,
) Error![]const u8 {
    const own = &standing.held.described;
    const added = try added_by(memory, standing, overs);
    const described = if (added) |*with| with else own;
    const list = described.fields_of(Described.root)[0];
    var laid: laid_module.Laid = .{};
    var layout: Layout = .{
        .gpa = memory,
        .scratch = memory,
        .described = described,
        .laid = &laid,
    };

    std.debug.assert(overs.len == standing.items.count);
    std.debug.assert(described.nodes[list.node].kind == .list);

    try layout.begin();
    standing.reading.next = 0;

    const where = try layout.items(list.node, list.offset, overs.len);
    const size = described.nodes[list.node].size;
    const to = described.nodes[list.node].child;

    for (overs, 0..) |over, index| {
        const position: u32 = @intCast(index);
        const kept = standing.at(position);
        const slot = where + size * position;

        if (over) |found| {
            try over_or_kept(&layout, to, slot, kept, found.answer.at(found.index));
        } else {
            try transfer.move(&layout, to, slot, kept.given, kept.node, kept.bytes);
        }
    }

    if (laid.block.items.len > applied.bytes_max) {
        return error.Invalid;
    }

    return held_module.pieced(memory, described.text, &laid);
}

/// The values' layout with the fields only the answers' type has, when it has any.
fn added_by(
    memory: std.mem.Allocator,
    standing: *const Opened,
    overs: []const ?Over,
) Error!?Described {
    const own = &standing.held.described;

    std.debug.assert(overs.len == standing.items.count);

    // Every answer of one modifier is of one type: the first says what it adds.
    for (overs) |over| {
        const found = over orelse continue;
        const wrote = &found.answer.held.described;
        const text = try merged_shape.of(
            memory,
            own,
            own.nodes[standing.list].child,
            wrote,
            wrote.nodes[found.answer.list].child,
            applied.field,
        ) orelse return null;

        return try described_module.parse(memory, text);
    }

    return null;
}

/// `wrote` laid over `kept` at `slot`; when it cannot be, what was built of it is taken
/// away, zero where it lay, and `kept` is built there as it was.
fn over_or_kept(
    layout: *Layout,
    to: u32,
    slot: u32,
    kept: merged.Source,
    wrote: merged.Source,
) Error!void {
    const laid = layout.laid;
    const block_len = laid.block.items.len;
    const addresses_len = laid.addresses.items.len;
    const table_len = laid.table.items.len;
    const kept_next = kept.given.next;
    const wrote_next = wrote.given.next;
    const size = layout.described.span(to);

    std.debug.assert(@as(u64, slot) + size <= block_len);

    merged.item(layout, to, slot, kept, wrote) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => {
            laid.block.items.len = block_len;
            laid.addresses.items.len = addresses_len;
            laid.table.items.len = table_len;
            @memset(laid.block.items[slot..][0..size], 0);
            kept.given.next = kept_next;
            wrote.given.next = wrote_next;

            try transfer.move(layout, to, slot, kept.given, kept.node, kept.bytes);
            try wrote.given.skip(wrote.node, wrote.bytes);
        },
    };
}

const Method = struct {
    id: []const u8,
    title: []const u8 = "",
    price: i64 = 0,
};

const Cart = struct {
    name: []const u8,
    note: []const u8 = "kept",
    price: ?i64 = null,
    parcel: struct {
        subtotal: i64,
        grams: u32 = 0,
    },
    methods: []const Method = &.{},
};

/// `changed`, a modifier's own values for every value of `values`, laid over them.
pub fn test_laid(
    comptime Value: type,
    comptime Changed: type,
    memory: std.mem.Allocator,
    values: []const Value,
    changed: []const Changed,
) ![]const Value {
    var standing: Opened = undefined;
    var answer: Opened = undefined;
    const overs = try memory.alloc(?Over, values.len);

    try standing.init(memory, try from_typed(Value, memory, values));
    try answer.init(memory, try from_typed(Changed, memory, changed));

    for (overs, 0..) |*over, index| {
        over.* = if (index < changed.len) .{
            .answer = &answer,
            .index = @intCast(index),
        } else null;
    }

    return to_typed(Value, memory, try laid_over(memory, &standing, overs));
}

test "a modifier's answer in its own type lies over the values: what it left out stays" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Priced = struct {
        price: ?i64 = null,
        name: []const u8 = "",
        parcel: struct {
            grams: u64 = 0,
        } = .{},
        unknown_to_owner: bool = true,
    };
    const carts = [_]Cart{
        .{
            .name = "Tea",
            .price = 500,
            .parcel = .{
                .subtotal = 900,
            },
        },
        .{
            .name = "Cup",
            .note = "second",
            .parcel = .{
                .subtotal = 100,
            },
        },
        .{
            .name = "Untouched",
            .parcel = .{
                .subtotal = 1,
            },
        },
    };
    const laid = try test_laid(Cart, Priced, arena, &carts, &.{
        .{
            .price = 450,
            .name = "Tea",
            .parcel = .{
                .grams = 120,
            },
        },
        .{
            .price = null,
            .name = "Mug",
        },
    });

    try std.testing.expectEqual(@as(usize, 3), laid.len);
    try std.testing.expectEqualStrings("Tea", laid[0].name);
    try std.testing.expectEqualStrings("kept", laid[0].note);
    try std.testing.expectEqual(@as(?i64, 450), laid[0].price);
    try std.testing.expectEqual(@as(i64, 900), laid[0].parcel.subtotal);
    try std.testing.expectEqual(@as(u32, 120), laid[0].parcel.grams);
    try std.testing.expectEqualStrings("Mug", laid[1].name);
    try std.testing.expectEqualStrings("second", laid[1].note);
    try std.testing.expectEqual(@as(?i64, null), laid[1].price);
    try std.testing.expectEqualStrings("Untouched", laid[2].name);
}

test "a list lies over a list by each item's id, or item by item; money key by key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Money = @import("../../publr/money.zig").Money;
    const Owned = struct {
        methods: []const Method,
        tags: []const []const u8 = &.{},
        total: Money = .{},
    };
    const Chosen = struct {
        methods: []const struct {
            id: []const u8,
            price: i64,
        },
        tags: []const []const u8,
        total: Money,
    };
    const owned = [_]Owned{.{
        .methods = &.{
            .{
                .id = "post",
                .title = "Post",
                .price = 400,
            },
            .{
                .id = "courier",
                .title = "Courier",
                .price = 900,
            },
        },
        .tags = &.{ "a", "b", "c" },
        .total = .{
            .amounts = &.{
                .{
                    .currency = "PLN",
                    .minor = 500,
                },
                .{
                    .currency = "EUR",
                    .minor = 100,
                },
            },
        },
    }};
    const laid = try test_laid(Owned, Chosen, arena, &owned, &.{.{
        .methods = &.{
            .{
                .id = "courier",
                .price = 0,
            },
            .{
                .id = "locker",
                .price = 300,
            },
        },
        .tags = &.{ "x", "y" },
        .total = .{
            .amounts = &.{
                .{
                    .currency = "PLN",
                    .minor = 450,
                },
                .{
                    .currency = "GBP",
                    .minor = 7,
                },
            },
        },
    }});
    const methods = laid[0].methods;

    try std.testing.expectEqual(@as(usize, 2), methods.len);
    try std.testing.expectEqualStrings("Courier", methods[0].title);
    try std.testing.expectEqual(@as(i64, 0), methods[0].price);
    try std.testing.expectEqualStrings("locker", methods[1].id);
    try std.testing.expectEqualStrings("", methods[1].title);
    try std.testing.expectEqual(@as(usize, 2), laid[0].tags.len);
    try std.testing.expectEqualStrings("y", laid[0].tags[1]);
    try std.testing.expectEqual(@as(?i64, 450), laid[0].total.get("PLN"));
    try std.testing.expectEqual(@as(?i64, 100), laid[0].total.get("EUR"));
    try std.testing.expectEqual(@as(?i64, 7), laid[0].total.get("GBP"));
}
