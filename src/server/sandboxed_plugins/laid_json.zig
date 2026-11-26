//! A value laid out for a plugin (`laid.zig`) from JSON: what core keeps as JSON (a
//! record's document), what the outer edge sent, and a field's default as its description
//! says it. An object fills a struct by its fields' names, or a keyed list by its keys; a
//! one-key object chooses a union's alternative; a text fills a decimal exactly.
const std = @import("std");
const free_json = @import("../../sdk/free_json.zig");
const model_decimal = @import("../../model/decimal.zig");
const described_module = @import("described.zig");
const laid_module = @import("laid.zig");

const Described = described_module.Described;
const Layout = laid_module.Layout;
const Laid = laid_module.Laid;
const Error = laid_module.Error;
const Value = std.json.Value;

pub fn left_out(layout: *Layout, field: described_module.Field, at: u32) Error!void {
    std.debug.assert(field.name.len > 0);

    if (field.default.len == 0) {
        return write(layout, field.node, null, at);
    }

    const said = field.default;
    const default = std.json.parseFromSliceLeaky(Value, layout.scratch, said, .{}) catch {
        return error.Invalid;
    };

    return write(layout, field.node, default, at);
}

pub fn write(layout: *Layout, node: u32, given: ?Value, at: u32) Error!void {
    const said = layout.described.nodes[node];

    std.debug.assert(node < layout.described.nodes.len);

    if (said.kind == .optional) {
        if (given == null or given.? == .null) {
            return;
        }

        layout.present(node, at);

        return write(layout, said.child, given, at);
    }

    const value = given orelse return error.Invalid;

    switch (said.kind) {
        .int => try layout.int(node, at, if (said.decimal)
            try units_of(value, said.places)
        else
            try integer_of(value)),
        .float => layout.float(node, at, try float_of(value)),
        .bool => layout.boolean(at, if (value == .bool) value.bool else return error.Invalid),
        .text => try layout.text(at, if (value == .string) value.string else {
            return error.Invalid;
        }),
        .free => try layout.free(at, (try free_json.from_tree(layout.scratch, value)).bytes),
        .enumeration => switch (value) {
            .string => |name| try layout.tag(node, at, name),
            .integer => |whole| try layout.tag_numbered(node, at, whole),
            else => return error.Invalid,
        },
        .pointer => try write(layout, said.child, value, try layout.pointee(node, at)),
        .choice => try write_choice(layout, node, value),
        .list => try write_list(layout, node, at, value),
        .object => try write_object(layout, node, at, value),
        .optional => unreachable,
    }
}

/// `{ "alternative": payload }`, or the alternative's name alone when it holds nothing.
fn write_choice(layout: *Layout, node: u32, value: Value) Error!void {
    const described = layout.described;

    std.debug.assert(described.nodes[node].kind == .choice);

    const name, const payload: ?Value = switch (value) {
        .string => |name| .{ name, null },
        .object => |object| if (object.count() == 1)
            .{ object.keys()[0], object.values()[0] }
        else
            return error.Invalid,
        else => return error.Invalid,
    };

    if (name.len == 0) {
        return error.Invalid;
    }

    const index = described.field_named(node, name, 0) orelse return error.Invalid;
    const alternative = described.alternatives_of(node)[index];
    const where = try layout.chosen(node, index);
    const inside = described.nodes[alternative.node];

    // An alternative that holds nothing is an object of no fields: nothing to write.
    if (inside.kind == .object and inside.count == 0 and !inside.tuple) {
        return;
    }

    return write(layout, alternative.node, payload, where);
}

fn write_list(layout: *Layout, node: u32, at: u32, value: Value) Error!void {
    const said = layout.described.nodes[node];

    std.debug.assert(said.kind == .list);

    if (said.keyed) {
        if (value != .object) {
            return error.Invalid;
        }

        const pair = layout.described.fields_of(said.child);
        const where = try layout.items(node, at, value.object.count());

        for (value.object.keys(), value.object.values(), 0..) |key, item, index| {
            const item_at = where + said.size * @as(u32, @intCast(index));

            try layout.text(item_at + pair[0].offset, key);
            try write(layout, pair[1].node, item, item_at + pair[1].offset);
        }

        return;
    }

    if (value != .array) {
        return error.Invalid;
    }

    const given = value.array.items;
    const where = try layout.items(node, at, given.len);

    for (given, 0..) |item, index| {
        try write(layout, said.child, item, where + said.size * @as(u32, @intCast(index)));
    }
}

fn write_object(layout: *Layout, node: u32, at: u32, value: Value) Error!void {
    const said = layout.described.nodes[node];
    const fields = layout.described.fields_of(node);

    std.debug.assert(said.kind == .object);

    if (said.tuple) {
        if (value != .array or value.array.items.len != fields.len) {
            return error.Invalid;
        }

        for (fields, value.array.items) |field, item| {
            try write(layout, field.node, item, at + field.offset);
        }

        return;
    }

    // A reference sent as its id alone: the first field, the others at their defaults.
    if (said.lone and value != .object) {
        try write(layout, fields[0].node, value, at + fields[0].offset);

        for (fields[1..]) |field| {
            try left_out(layout, field, at + field.offset);
        }

        return;
    }

    if (value != .object) {
        return error.Invalid;
    }

    for (fields) |field| {
        if (value.object.get(field.name)) |given| {
            try write(layout, field.node, given, at + field.offset);
        } else {
            try left_out(layout, field, at + field.offset);
        }
    }
}

fn integer_of(value: Value) Error!i64 {
    std.debug.assert(value != .object or value.object.count() < std.math.maxInt(u32));

    return switch (value) {
        .integer => |inner| inner,
        .float => |inner| if (@round(inner) == inner and @abs(inner) < 1 << 62)
            @intFromFloat(inner)
        else
            error.Invalid,
        .bool => |inner| @intFromBool(inner),
        .number_string, .string => |inner| std.fmt.parseInt(i64, inner, 10) catch {
            return error.Invalid;
        },
        else => error.Invalid,
    };
}

/// A decimal's units from its exact text, or from a whole number of it.
fn units_of(value: Value, places: u8) Error!i64 {
    if (places > model_decimal.places_max) {
        return error.Invalid;
    }

    std.debug.assert(places <= model_decimal.places_max);

    return switch (value) {
        .string, .number_string => |text| model_decimal.units_of(text, places) catch {
            return error.Invalid;
        },
        .integer => |whole| std.math.mul(i64, whole, std.math.powi(i64, 10, places) catch {
            return error.Invalid;
        }) catch error.Invalid,
        else => error.Invalid,
    };
}

fn float_of(value: Value) Error!f64 {
    std.debug.assert(value != .object or value.object.count() < std.math.maxInt(u32));

    return switch (value) {
        .float => |inner| inner,
        .integer => |inner| @floatFromInt(inner),
        .number_string, .string => |inner| std.fmt.parseFloat(f64, inner) catch {
            return error.Invalid;
        },
        else => error.Invalid,
    };
}

/// `json` laid out as the description says, at address 0; the block is `gpa`'s.
pub fn from_json(
    gpa: std.mem.Allocator,
    scratch: std.mem.Allocator,
    described: *const Described,
    json: []const u8,
) Error!Laid {
    std.debug.assert(json.len > 0);

    const value = std.json.parseFromSliceLeaky(Value, scratch, json, .{}) catch {
        return error.Invalid;
    };
    var laid: Laid = .{};
    errdefer laid.deinit(gpa);

    var layout: Layout = .{
        .gpa = gpa,
        .scratch = scratch,
        .described = described,
        .laid = &laid,
    };

    const root = described.nodes[Described.root].kind;

    if (root != .object and root != .free) {
        return error.Invalid;
    }

    try layout.begin();
    try write(&layout, Described.root, value, 0);

    return laid;
}

const shape_wire = @import("../../sdk/plugin/shape_wire.zig");

test "JSON lays out as a description says; what it leaves out takes the field's default" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const given_module = @import("given.zig");
    const Line = struct {
        name: []const u8,
        note: ?[]const u8 = null,
        count: ?u32 = null,
        tags: []const []const u8 = &.{},
        kind: enum { item, step } = .step,
        size: i8 = -2,
    };
    const described = try described_module.parse(arena, comptime shape_wire.describe(Line));
    var laid = try from_json(arena, arena, &described, "{\"name\":\"Tea\",\"count\":3}");

    laid.place(64);

    var given: given_module.Given = .{
        .described = &described,
        .memory = .{
            .block = .{
                .base = 64,
                .bytes = laid.block.items,
            },
        },
        .arena = arena,
    };
    const window = try given.window(Described.root, 64);

    try std.testing.expectEqualStrings(
        "{\"name\":\"Tea\",\"note\":null,\"count\":3,\"tags\":[],\"kind\":\"step\",\"size\":-2}",
        try given.json_of(Described.root, window, .null),
    );
    try std.testing.expectEqualStrings(
        "{\"name\":\"Tea\",\"count\":3,\"tags\":[],\"kind\":\"step\",\"size\":-2}",
        try given.json_of(Described.root, window, .left_out),
    );

    // A number its field cannot hold, a tag its enum does not have, a name left out.
    const over = "{\"name\":\"Tea\",\"size\":300}";
    const unknown = "{\"name\":\"Tea\",\"kind\":\"box\"}";

    try std.testing.expectError(error.Invalid, from_json(arena, arena, &described, over));
    try std.testing.expectError(error.Invalid, from_json(arena, arena, &described, unknown));
    try std.testing.expectError(error.Invalid, from_json(arena, arena, &described, "{}"));
    try std.testing.expectError(error.Invalid, from_json(arena, arena, &described, "[1]"));
}

test "every form a description says lays out from JSON and is written back the same" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const given_module = @import("given.zig");
    const Money = @import("../../sdk/money.zig").Money;
    const Free = @import("../../publr/operation/json.zig").Laid;
    const Decimal = @import("../../sdk/plugin/decimal.zig").Decimal(3);
    const Ref = struct {
        id: []const u8,
        missing: bool = false,

        pub const publr_form = .lone;
    };
    const Node = struct {
        name: []const u8,
        price: Money = .{},
        weight: Decimal,
        item: Ref,
        pair: struct {
            u8,
            bool,
        },
        choice: union(enum) {
            none,
            count: u32,
        },
        facts: Free,
        next: ?*const @This() = null,
        children: []const @This() = &.{},
    };
    const described = try described_module.parse(arena, comptime shape_wire.describe(Node));
    const leaf = "{\"name\":\"b\",\"price\":{},\"weight\":\"0.500\",\"item\":\"r2\"," ++
        "\"pair\":[0,false],\"choice\":{\"none\":{}},\"facts\":null,\"next\":null,\"children\":[]}";
    const text = "{\"name\":\"a\",\"price\":{\"PLN\":12300,\"EUR\":5},\"weight\":\"1.250\"," ++
        "\"item\":\"r1\",\"pair\":[7,true],\"choice\":{\"count\":2}," ++
        "\"facts\":{\"tags\":[\"x\",1.5,null]},\"next\":" ++ leaf ++ ",\"children\":[" ++
        leaf ++ "]}";
    var laid = try from_json(arena, arena, &described, text);

    laid.place(64);

    var given: given_module.Given = .{
        .described = &described,
        .memory = .{
            .block = .{
                .base = 64,
                .bytes = laid.block.items,
            },
        },
        .arena = arena,
        .table = laid.table.items,
    };
    const window = try given.window(Described.root, 64);

    try std.testing.expectEqualStrings(text, try given.json_of(Described.root, window, .null));
    try std.testing.expectEqual(@as(usize, 3), laid.table.items.len);

    // A reference sent as an object holding its id; a decimal of too many places; a union
    // of an alternative it does not have.
    const object = try std.mem.replaceOwned(u8, arena, leaf, "\"r2\"", "{\"id\":\"r2\"}");
    const places = try std.mem.replaceOwned(u8, arena, leaf, "0.500", "0.5001");
    const unknown = try std.mem.replaceOwned(u8, arena, leaf, "none", "other");

    _ = try from_json(arena, arena, &described, object);
    try std.testing.expectError(error.Invalid, from_json(arena, arena, &described, places));
    try std.testing.expectError(error.Invalid, from_json(arena, arena, &described, unknown));
}
