//! The values of one apply (`ctx.mod`, `mod.apply`) as core holds them between two
//! modifiers: one piece (`held.zig`) whose value is `{ items: [...] }`, each item in the
//! layout its owner described. They are copied out of the owner once, each modifier's answer
//! is laid over them where they lie (`merged.zig`), and they go back to the owner in its own
//! layout: no text on the way.
const std = @import("std");
const mods = @import("../../sdk/mods.zig");
const shape_wire = @import("../../sdk/plugin/shape_wire.zig");
const described_module = @import("described.zig");
const described_text = @import("described_text.zig");
const given_module = @import("given.zig");
const given_typed = @import("given_typed.zig");
const laid_module = @import("laid.zig");
const laid_typed = @import("laid_typed.zig");
const held_module = @import("held.zig");
const merged = @import("merged.zig");
const transfer = @import("transfer.zig");

const Described = described_module.Described;
const Given = given_module.Given;
const Layout = laid_module.Layout;

pub const Error = error{ Invalid, OutOfMemory };

/// The one field of what is held: the values, in order.
pub const field = "items";

/// The most the values of one apply may take laid out, as the JSON they came as before.
pub const bytes_max: u32 = 1 << 20;

/// What core's own code applies: a struct of one field, the values.
pub fn Items(comptime Value: type) type {
    return struct {
        items: []const Value,
    };
}

/// A piece opened: its values, to read one by one.
pub const Opened = struct {
    held: held_module.Held,
    reading: Given,
    /// The list the values are, and where its two words lie in the root.
    list: u32,
    offset: u32,
    items: Given.Items,

    /// `piece` opened in place: `opened` is read where it stands, never moved.
    pub fn init(opened: *Opened, memory: std.mem.Allocator, piece: []const u8) Error!void {
        opened.held = try held_module.open(memory, piece);
        opened.reading = opened.held.given(memory);

        const described = &opened.held.described;

        if (described.nodes[Described.root].kind != .object) {
            return error.Invalid;
        }

        const window = try opened.held.window(&opened.reading);
        const index = described.field_named(Described.root, field, 0) orelse return error.Invalid;
        const found = described.fields_of(Described.root)[index];
        const list = described.nodes[found.node];

        if (list.kind != .list or list.keyed) {
            return error.Invalid;
        }

        opened.list = found.node;
        opened.offset = found.offset;
        opened.items = try opened.reading.items(found.node, window[found.offset..]);

        if (opened.items.count > mods.items_max) {
            return error.Invalid;
        }

        std.debug.assert(opened.items.count <= mods.items_max);
    }

    pub fn at(opened: *Opened, index: u32) merged.Source {
        std.debug.assert(index < opened.items.count);

        return .{
            .given = &opened.reading,
            .node = opened.held.described.nodes[opened.list].child,
            .bytes = opened.items.at(index),
        };
    }
};

/// The values an installed plugin applies, where they lie in its memory as list `node` at
/// `bytes`: copied whole, every address checked, one piece in `memory`.
pub fn from_given(
    memory: std.mem.Allocator,
    given: *Given,
    node: u32,
    bytes: []const u8,
) Error![]const u8 {
    const said = given.described.nodes[node];

    if (said.kind != .list or said.keyed) {
        return error.Invalid;
    }

    if (std.mem.readInt(u32, bytes[4..8], .little) > mods.items_max) {
        return error.Invalid;
    }

    const text = try described_text.wrapped(memory, given.described, node, field);
    const described = try described_module.parse(memory, text);
    var laid: laid_module.Laid = .{};
    var layout: Layout = .{
        .gpa = memory,
        .scratch = memory,
        .described = &described,
        .laid = &laid,
    };
    const items = described.fields_of(Described.root)[0];

    std.debug.assert(std.mem.eql(u8, items.name, field));

    try layout.begin();
    try transfer.move(&layout, items.node, items.offset, given, node, bytes);

    if (laid.block.items.len > bytes_max) {
        return error.Invalid;
    }

    return held_module.pieced(memory, text, &laid);
}

/// Core's own values, or a compiled-in plugin's, laid out as one piece in `memory`.
pub fn from_typed(
    comptime Value: type,
    memory: std.mem.Allocator,
    values: []const Value,
) Error![]const u8 {
    const text = comptime shape_wire.describe(Items(Value));
    const described = try described_module.parse(memory, text);
    const batch: Items(Value) = .{
        .items = values,
    };
    var laid: laid_module.Laid = .{};
    var layout: Layout = .{
        .gpa = memory,
        .scratch = memory,
        .described = &described,
        .laid = &laid,
    };

    if (values.len > mods.items_max) {
        return error.Invalid;
    }

    std.debug.assert(values.len <= mods.items_max);

    try layout.begin();
    try laid_typed.lay(Items(Value), &layout, Described.root, &batch, 0);

    return held_module.pieced(memory, text, &laid);
}

/// The values of `piece` as `Value`s, in `memory`: all of them, or `Invalid`.
pub fn to_typed(
    comptime Value: type,
    memory: std.mem.Allocator,
    piece: []const u8,
) Error![]const Value {
    const held = try held_module.open(memory, piece);
    var reading = held.given(memory);
    const window = try held.window(&reading);

    std.debug.assert(piece.len > 0);

    const read = try given_typed.read(Items(Value), &reading, Described.root, window, .{
        .ignore_unknown = true,
        .absent = .null,
    });

    return read.items;
}

/// One value of `opened` alone, as a piece of its own.
pub fn one(memory: std.mem.Allocator, opened: *Opened, index: u32) Error![]const u8 {
    const described = &opened.held.described;
    var laid: laid_module.Laid = .{};
    var layout: Layout = .{
        .gpa = memory,
        .scratch = memory,
        .described = described,
        .laid = &laid,
    };
    const source = opened.at(index);

    std.debug.assert(index < opened.items.count);

    try layout.begin();

    const where = try layout.items(opened.list, opened.offset, 1);

    // The unions of the values before it are stepped over: this one's come next.
    opened.reading.next = 0;

    for (0..index) |before| {
        const earlier = opened.at(@intCast(before));

        try opened.reading.skip(earlier.node, earlier.bytes);
    }

    try transfer.move(&layout, source.node, where, source.given, source.node, source.bytes);
    opened.reading.next = 0;

    return held_module.pieced(memory, described.text, &laid);
}

const applied_over = @import("applied_over.zig");
const applied_typed = @import("applied_typed.zig");
const applied_trees = @import("applied_trees.zig");

pub const Over = applied_over.Over;
pub const laid_over = applied_over.laid_over;
pub const Fitting = applied_typed.Fitting;
pub const fitting = applied_typed.fitting;
pub const answered = applied_typed.answered;
pub const from_trees = applied_trees.from_trees;
pub const to_trees = applied_trees.to_trees;

test {
    _ = merged;
    _ = @import("merged_tree.zig");
    _ = @import("merged_shape.zig");
    _ = @import("given_tree.zig");
    _ = described_text;
    _ = applied_over;
    _ = applied_typed;
    _ = applied_trees;
}

const Method = struct {
    id: []const u8,
    title: []const u8 = "",
    price: i64 = 0,
};

/// `value` laid out by its own description as one piece: what a plugin may answer.
fn test_piece(comptime Shape: type, memory: std.mem.Allocator, value: Shape) ![]const u8 {
    const text = comptime shape_wire.describe(Shape);
    const described = try described_module.parse(memory, text);
    var laid: laid_module.Laid = .{};
    var layout: Layout = .{
        .gpa = memory,
        .scratch = memory,
        .described = &described,
        .laid = &laid,
    };

    std.debug.assert(text.len > 0);

    try layout.begin();
    try laid_typed.lay(Shape, &layout, Described.root, &value, 0);

    return held_module.pieced(memory, text, &laid);
}

test "an answer that is not the values of an apply is never read as them" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Money = @import("../../publr/money.zig").Money;
    const Other = struct {
        other: u32,
    };
    const Number = struct {
        items: u32,
    };
    const Keyed = struct {
        items: Money,
    };
    const many: [mods.items_max + 1]u8 = @splat(1);
    var opened: Opened = undefined;
    var standing: Opened = undefined;

    // No `items`, `items` that is no list, a keyed list, more values than an apply takes,
    // and bytes that are no piece at all.
    const wrong = [_][]const u8{
        try test_piece(Other, arena, .{
            .other = 1,
        }),
        try test_piece(Number, arena, .{
            .items = 1,
        }),
        try test_piece(Keyed, arena, .{
            .items = .{},
        }),
        try test_piece(Items(u8), arena, .{
            .items = &many,
        }),
        "not a piece",
    };

    for (wrong) |piece| {
        try std.testing.expectError(error.Invalid, opened.init(arena, piece));
    }

    try std.testing.expectError(error.Invalid, from_typed(u8, arena, &many));

    // An answer of another type altogether leaves every value as it was.
    try standing.init(arena, try from_typed(Method, arena, &.{.{
        .id = "post",
        .price = 4,
    }}));
    try opened.init(arena, try from_typed([]const u8, arena, &.{"text"}));

    const kept = try to_typed(Method, arena, try laid_over(arena, &standing, &.{.{
        .answer = &opened,
        .index = 0,
    }}));

    try std.testing.expectEqualStrings("post", kept[0].id);
    try std.testing.expectEqual(@as(i64, 4), kept[0].price);
}
