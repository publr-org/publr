//! One of core's own values laid out for a plugin straight from the struct: fields found by
//! their names in the layout the plugin described, in the order it described them, so the
//! unions beside the block come as the plugin reads them. No JSON is written or parsed on the
//! way, but where core's own type is JSON by its definition: what core keeps as JSON
//! (`operation.Json`, read once) and a type that says how it writes itself
//! (`jsonStringify`), laid out by `laid_json.zig`.
const std = @import("std");
const operation = @import("../../sdk/operation.zig");
const laid_module = @import("laid.zig");
const given_typed = @import("given_typed.zig");

const Layout = laid_module.Layout;

pub const Error = laid_module.Error;

/// `value` written at `at` as `node` says.
pub fn lay(
    comptime Shape: type,
    layout: *Layout,
    node: u32,
    value: *const Shape,
    at: u32,
) Error!void {
    const said = layout.described.nodes[node];

    std.debug.assert(node < layout.described.nodes.len);

    // Kept or written as JSON by core, or taken by the plugin as a value whose shape comes
    // with the data: read once, here.
    const own = comptime Shape == operation.Json or given_typed.through_json(Shape);

    if (own or said.kind == .free or said.kind == .choice) {
        const text = try written(Shape, layout, value);
        const tree = std.json.parseFromSliceLeaky(std.json.Value, layout.scratch, text, .{}) catch {
            return error.Invalid;
        };

        return layout.write(node, tree, at);
    }

    if (said.kind == .pointer) {
        return lay(Shape, layout, said.child, value, try layout.pointee(node, at));
    }

    if (@typeInfo(Shape) == .optional) {
        if (value.*) |*inner| {
            return lay(@typeInfo(Shape).optional.child, layout, node, inner, at);
        }

        // Nothing, where the plugin's type must hold something.
        return if (said.kind == .optional) {} else error.Invalid;
    }

    if (said.kind == .optional) {
        layout.present(node, at);

        return lay(Shape, layout, said.child, value, at);
    }

    // A reference the plugin keeps whole, where core's value is its id alone.
    if (said.kind == .object and said.lone and comptime @typeInfo(Shape) != .@"struct") {
        const fields = layout.described.fields_of(node);

        try lay(Shape, layout, fields[0].node, value, at + fields[0].offset);

        for (fields[1..]) |field| {
            try layout.left_out(field, at + field.offset);
        }

        return;
    }

    switch (@typeInfo(Shape)) {
        .int => try lay_int(layout, node, at, value.*),
        .float => try lay_float(layout, node, at, value.*),
        .bool => switch (said.kind) {
            .bool => layout.boolean(at, value.*),
            .int => try layout.int(node, at, @intFromBool(value.*)),
            else => return error.Invalid,
        },
        .@"enum" => try lay_text(layout, node, at, @tagName(value.*)),
        .pointer => |info| if (info.child == u8)
            try lay_text(layout, node, at, value.*)
        else
            try lay_list(info.child, layout, node, value.*, at),
        .@"struct" => try lay_object(Shape, layout, node, value, at),
        else => @compileError(@typeName(Shape) ++ " is laid out through its JSON"),
    }
}

/// `value` as JSON text: core's own text for what it keeps as JSON.
fn written(comptime Shape: type, layout: *Layout, value: *const Shape) Error![]const u8 {
    if (Shape == operation.Json) {
        std.debug.assert(value.text.len > 0);

        return value.text;
    }

    return std.json.Stringify.valueAlloc(layout.scratch, value.*, .{}) catch error.OutOfMemory;
}

fn lay_int(layout: *Layout, node: u32, at: u32, value: i128) Error!void {
    const said = layout.described.nodes[node];

    std.debug.assert(said.kind != .optional and said.kind != .free);

    switch (said.kind) {
        .int => try layout.int(node, at, value),
        .float => layout.float(node, at, @floatFromInt(value)),
        else => return error.Invalid,
    }
}

fn lay_float(layout: *Layout, node: u32, at: u32, value: f64) Error!void {
    const said = layout.described.nodes[node];

    std.debug.assert(said.kind != .optional and said.kind != .free);

    switch (said.kind) {
        .float => layout.float(node, at, value),
        .int => {
            if (@round(value) != value or @abs(value) >= 1 << 62) {
                return error.Invalid;
            }

            try layout.int(node, at, @as(i64, @intFromFloat(value)));
        },
        else => return error.Invalid,
    }
}

/// A text, or an enum's tag by its name: as a text, or as the plugin's tag of that name.
fn lay_text(layout: *Layout, node: u32, at: u32, value: []const u8) Error!void {
    const said = layout.described.nodes[node];

    std.debug.assert(said.kind != .optional and said.kind != .free);

    switch (said.kind) {
        .text => {
            if (!std.unicode.utf8ValidateSlice(value)) {
                return error.Invalid;
            }

            try layout.text(at, value);
        },
        .enumeration => try layout.tag(node, at, value),
        .int => try layout.int(node, at, std.fmt.parseInt(i64, value, 10) catch {
            return error.Invalid;
        }),
        .float => layout.float(node, at, std.fmt.parseFloat(f64, value) catch {
            return error.Invalid;
        }),
        else => return error.Invalid,
    }
}

fn lay_list(
    comptime Item: type,
    layout: *Layout,
    node: u32,
    values: []const Item,
    at: u32,
) Error!void {
    const said = layout.described.nodes[node];

    if (said.kind != .list) {
        return error.Invalid;
    }

    const where = try layout.items(node, at, values.len);

    std.debug.assert(values.len <= std.math.maxInt(u32));

    for (values, 0..) |*item, index| {
        try lay(Item, layout, said.child, item, where + said.size * @as(u32, @intCast(index)));
    }
}

fn lay_object(
    comptime Shape: type,
    layout: *Layout,
    node: u32,
    value: *const Shape,
    at: u32,
) Error!void {
    const info = @typeInfo(Shape).@"struct";

    if (layout.described.nodes[node].kind != .object) {
        return error.Invalid;
    }

    std.debug.assert(!info.is_tuple);

    for (layout.described.fields_of(node), 0..) |field, position| {
        const index = given_typed.index_of(Shape, field.name, @intCast(position)) orelse {
            try layout.left_out(field, at + field.offset);
            continue;
        };

        inline for (info.field_names, info.field_types, 0..) |name, Field, own| {
            if (index == own) {
                if (comptime given_typed.carried(Shape, own)) {
                    try lay(Field, layout, field.node, &@field(value.*, name), at + field.offset);
                } else {
                    try layout.left_out(field, at + field.offset);
                }
            }
        }
    }
}

const shape_wire = @import("../../sdk/plugin/shape_wire.zig");
const described_module = @import("described.zig");
const given_module = @import("given.zig");

test "core's struct lays out in a plugin's layout: by name, null as nothing, zero between" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Core = struct {
        count: u64,
        kind: enum { step, item },
        weight: ?f64,
        note: ?[]const u8,
        inner: struct {
            level: ?i32,
            on: bool,
        },
        hidden: u8 = 3,
    };
    const Wanted = struct {
        on_top: bool = true,
        kind: enum { item, step },
        count: u16,
        weight: ?f32,
        inner: struct {
            on: bool,
            level: ?i8,
        },
        size: i8 = -2,
    };
    const described = try described_module.parse(arena, comptime shape_wire.describe(Wanted));
    const core: Core = .{
        .count = 7,
        .kind = .item,
        .weight = null,
        .note = null,
        .inner = .{
            .level = -4,
            .on = true,
        },
    };
    var laid: laid_module.Laid = .{};
    var layout: Layout = .{
        .gpa = arena,
        .scratch = arena,
        .described = &described,
        .laid = &laid,
    };

    try layout.begin();
    try lay(Core, &layout, 0, &core, 0);

    // The block is the plugin's struct, byte for byte: a 64-bit host lays these types out as
    // a plugin does, for they hold no address.
    var wanted: Wanted = undefined;

    @memcpy(std.mem.asBytes(&wanted), laid.block.items[0..@sizeOf(Wanted)]);
    try std.testing.expect(wanted.on_top and wanted.kind == .item and wanted.count == 7);
    try std.testing.expect(wanted.weight == null and wanted.size == -2);
    try std.testing.expect(wanted.inner.on and wanted.inner.level.? == -4);

    // Nothing of core's lies between the fields: the padding is zero.
    try std.testing.expect(try described_module.padding_is_zero(&described, laid.block.items));

    // A number the plugin's field cannot hold is refused, never cut.
    var large = core;

    large.count = 70_000;
    laid = .{};
    try layout.begin();
    try std.testing.expectError(error.Invalid, lay(Core, &layout, 0, &large, 0));
}
