//! A value a plugin handed over (`given.zig`) as the tree it stands for, read where it
//! lies: what `given_json.zig` writes as text, with no text written. For a merge whose
//! other side is a value whose shape comes with the data (`merged.zig`).
const std = @import("std");
const free_json = @import("../../sdk/free_json.zig");
const model_decimal = @import("../../model/decimal.zig");
const given_module = @import("given.zig");

const Given = given_module.Given;
const Absent = given_module.Absent;
const Value = std.json.Value;

pub const Error = given_module.Error;

/// The value of `node` at `bytes` as a tree, in the arena of `given`.
pub fn of(given: *Given, node: u32, bytes: []const u8, absent: Absent) Error!Value {
    const said = given.described.nodes[node];

    std.debug.assert(bytes.len >= given.described.span(node));

    switch (said.kind) {
        .int => return whole(given, node, bytes),
        .float => return .{
            .float = given.float(node, bytes),
        },
        .bool => return .{
            .bool = bytes[0] != 0,
        },
        .text => return .{
            .string = try given.text(bytes),
        },
        .free => return free_json.tree_of(given.arena, .{
            .bytes = try given.free(bytes),
        }),
        .enumeration => return .{
            .string = try given.tag(node, bytes),
        },
        .optional => {
            if (!given.present(node, bytes)) {
                return .null;
            }

            return of(given, said.child, bytes, absent);
        },
        .pointer => {
            try given.enter();
            defer given.leave();

            return of(given, said.child, try given.pointee(node, bytes), absent);
        },
        .choice => return chosen(given, node, absent),
        .list => return if (said.keyed) keyed(given, node, bytes, absent) else listed(
            given,
            node,
            bytes,
            absent,
        ),
        .object => return object(given, node, bytes, absent),
    }
}

/// A whole number; a decimal's units as its exact text.
fn whole(given: *Given, node: u32, bytes: []const u8) Error!Value {
    const said = given.described.nodes[node];
    const held = given.int(node, bytes);

    std.debug.assert(said.kind == .int);

    if (said.decimal) {
        var buffer: [model_decimal.text_len_max]u8 = undefined;

        if (said.places > model_decimal.places_max) {
            return error.Invalid;
        }

        const text = model_decimal.text_of(@intCast(held), said.places, &buffer);

        return .{
            .string = given.arena.dupe(u8, text) catch return error.OutOfMemory,
        };
    }

    if (std.math.cast(i64, held)) |fits| {
        return .{
            .integer = fits,
        };
    }

    return .{
        .number_string = std.fmt.allocPrint(given.arena, "{d}", .{held}) catch {
            return error.OutOfMemory;
        },
    };
}

/// A union: `{ "alternative": payload }`.
fn chosen(given: *Given, node: u32, absent: Absent) Error!Value {
    const held = try given.chosen(node);
    var made: std.json.ObjectMap = .empty;

    std.debug.assert(held.index < given.described.alternatives_of(node).len);

    try given.enter();
    defer given.leave();

    made.put(
        given.arena,
        given.described.alternatives_of(node)[held.index].name,
        try of(given, held.node, held.bytes, absent),
    ) catch return error.OutOfMemory;

    return .{
        .object = made,
    };
}

fn listed(given: *Given, node: u32, bytes: []const u8, absent: Absent) Error!Value {
    const said = given.described.nodes[node];
    const list = try given.items(node, bytes);
    var made = std.json.Array.initCapacity(given.arena, list.count) catch {
        return error.OutOfMemory;
    };

    std.debug.assert(said.kind == .list and !said.keyed);

    try given.enter();
    defer given.leave();

    for (0..list.count) |index| {
        made.appendAssumeCapacity(try of(given, said.child, list.at(@intCast(index)), absent));
    }

    return .{
        .array = made,
    };
}

/// A keyed list: an object, each pair's first field its key.
fn keyed(given: *Given, node: u32, bytes: []const u8, absent: Absent) Error!Value {
    const said = given.described.nodes[node];
    const list = try given.items(node, bytes);
    const pair = given.described.fields_of(said.child);
    var made: std.json.ObjectMap = .empty;

    std.debug.assert(said.keyed and pair.len == 2);

    try given.enter();
    defer given.leave();

    for (0..list.count) |index| {
        const item = list.at(@intCast(index));
        const key = try given.text(item[pair[0].offset..]);
        const value = try of(given, pair[1].node, item[pair[1].offset..], absent);

        made.put(given.arena, key, value) catch return error.OutOfMemory;
    }

    return .{
        .object = made,
    };
}

fn object(given: *Given, node: u32, bytes: []const u8, absent: Absent) Error!Value {
    const said = given.described.nodes[node];
    const fields = given.described.fields_of(node);

    std.debug.assert(said.kind == .object);

    if (said.lone) {
        // What the other fields' unions wrote beside the block is passed all the same.
        const first = try of(given, fields[0].node, bytes[fields[0].offset..], absent);

        for (fields[1..]) |field| {
            try given.skip(field.node, bytes[field.offset..]);
        }

        return first;
    }

    if (said.tuple) {
        var made = std.json.Array.initCapacity(given.arena, fields.len) catch {
            return error.OutOfMemory;
        };

        for (fields) |field| {
            made.appendAssumeCapacity(try of(given, field.node, bytes[field.offset..], absent));
        }

        return .{
            .array = made,
        };
    }

    var made: std.json.ObjectMap = .empty;

    for (fields) |field| {
        const inside = bytes[field.offset..];
        const optional = given.described.nodes[field.node].kind == .optional;

        if (absent == .left_out and optional and !given.present(field.node, inside)) {
            continue;
        }

        made.put(given.arena, field.name, try of(given, field.node, inside, absent)) catch {
            return error.OutOfMemory;
        };
    }

    return .{
        .object = made,
    };
}

const shape_wire = @import("../../sdk/plugin/shape_wire.zig");
const described_module = @import("described.zig");
const laid_module = @import("laid.zig");
const laid_typed = @import("laid_typed.zig");
const held_module = @import("held.zig");

test "a value read as a tree is the tree its JSON text reads as" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Money = @import("../../publr/money.zig").Money;
    const Decimal = @import("../../publr/plugin/decimal.zig").Decimal;
    const Shape = struct {
        title: []const u8,
        count: u64,
        small: i8,
        ratio: f64,
        on: bool,
        kind: enum { item, step },
        note: ?[]const u8,
        left: ?u32,
        total: Money,
        quantity: Decimal(3),
        tags: []const []const u8,
        choice: union(enum) {
            none,
            count: u32,
        },
        inner: struct {
            level: ?i8,
        },
    };
    const value: Shape = .{
        .title = "Tea \"50 g\"",
        .count = std.math.maxInt(u64),
        .small = -3,
        .ratio = 1.5,
        .on = true,
        .kind = .step,
        .note = null,
        .left = 4,
        .total = .{
            .amounts = &.{.{
                .currency = "PLN",
                .minor = 500,
            }},
        },
        .quantity = Decimal(3).of(1250),
        .tags = &.{ "a", "b" },
        .choice = .{
            .count = 9,
        },
        .inner = .{
            .level = null,
        },
    };
    const text = comptime shape_wire.describe(Shape);
    const described = try described_module.parse(arena, text);
    var laid: laid_module.Laid = .{};
    var layout: laid_module.Layout = .{
        .gpa = arena,
        .scratch = arena,
        .described = &described,
        .laid = &laid,
    };

    try layout.begin();
    try laid_typed.lay(Shape, &layout, 0, &value, 0);

    const held = try held_module.open(arena, try held_module.pieced(arena, text, &laid));

    inline for (.{ Absent.null, Absent.left_out }) |absent| {
        var reading = held.given(arena);
        var again = held.given(arena);
        const tree = try of(&reading, 0, try held.window(&reading), absent);
        const written = try again.json_of(0, try held.window(&again), absent);
        const direct = try std.json.Stringify.valueAlloc(arena, tree, .{});
        const parsed = try std.json.parseFromSliceLeaky(Value, arena, written, .{});

        try std.testing.expectEqualStrings(
            try std.json.Stringify.valueAlloc(arena, parsed, .{}),
            direct,
        );
    }
}
