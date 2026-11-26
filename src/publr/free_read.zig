//! A value whose shape comes with the data (`free_value.zig`) read as a struct, with no text
//! in between: `value.as(Line, arena)`. The other way is `free_typed.zig`.
const std = @import("std");
const free_value = @import("free_value.zig");
const shape_wire = @import("../sdk/plugin/shape_wire.zig");

const Value = free_value.Value;

pub const Error = error{ Invalid, OutOfMemory };

/// `value` read as a `Shape`: fields by their names, one the value lacks at its default, one
/// the struct lacks left behind. Lists and what a text is copied into live in `arena`;
/// texts stay where the value lies.
pub fn as(comptime Shape: type, arena: std.mem.Allocator, value: Value) Error!Shape {
    if (Shape == Value) {
        return value;
    }

    if (Shape == std.json.Value) {
        return @import("../sdk/free_json.zig").tree_of(arena, value);
    }

    switch (@typeInfo(Shape)) {
        .int => {
            if (value.int()) |whole| {
                return std.math.cast(Shape, whole) orelse error.Invalid;
            }

            const real = value.float() orelse return error.Invalid;

            if (@round(real) != real or @abs(real) >= 1 << 62) {
                return error.Invalid;
            }

            return std.math.cast(Shape, @as(i64, @intFromFloat(real))) orelse error.Invalid;
        },
        .float => return @floatCast(value.float() orelse return error.Invalid),
        .bool => return value.boolean() orelse error.Invalid,
        .@"enum" => {
            const name = value.text() orelse return error.Invalid;

            return std.meta.stringToEnum(Shape, name) orelse error.Invalid;
        },
        .optional => |info| {
            if (value.is_null()) {
                return null;
            }

            return try as(info.child, arena, value);
        },
        .pointer => |info| {
            if (info.size == .one) {
                const made = arena.create(info.child) catch return error.OutOfMemory;

                made.* = try as(info.child, arena, value);

                return made;
            }

            if (info.child == u8) {
                return value.text() orelse error.Invalid;
            }

            return list_as(info.child, arena, value);
        },
        .@"struct" => return struct_as(Shape, arena, value),
        .@"union" => |info| {
            var walk = value.entries();
            const entry = walk.next() orelse return error.Invalid;

            inline for (info.field_names, info.field_types) |name, Payload| {
                if (std.mem.eql(u8, entry.key, name)) {
                    if (comptime Payload == void) {
                        return @unionInit(Shape, name, {});
                    }

                    return @unionInit(Shape, name, try as(Payload, arena, entry.value));
                }
            }

            return error.Invalid;
        },
        .void => return {},
        else => @compileError(@typeName(Shape) ++ " cannot be read from a free-form value"),
    }
}

fn list_as(comptime Item: type, arena: std.mem.Allocator, value: Value) Error![]Item {
    if (value.kind() != .list) {
        return error.Invalid;
    }

    const made = arena.alloc(Item, value.count()) catch return error.OutOfMemory;
    var walk = value.items();

    for (made) |*item| {
        item.* = try as(Item, arena, walk.next() orelse return error.Invalid);
    }

    std.debug.assert(made.len == value.count());

    return made;
}

fn struct_as(comptime Shape: type, arena: std.mem.Allocator, value: Value) Error!Shape {
    const info = @typeInfo(Shape).@"struct";
    const form = comptime shape_wire.form_of(Shape);

    std.debug.assert(value.bytes.len > 0);

    switch (form) {
        .inner => return only(Shape, try as(
            @FieldType(Shape, shape_wire.only_field(Shape)),
            arena,
            value,
        )),
        .free => return only(Shape, value.bytes),
        .json => return only(Shape, try @import("../sdk/free_json.zig").text_of(arena, value)),
        .decimal => {
            if (value.int()) |whole| {
                return Shape.of(whole);
            }

            return Shape.parse(value.text() orelse return error.Invalid);
        },
        .keyed => return only(Shape, try pairs_as(
            @typeInfo(@FieldType(Shape, shape_wire.only_field(Shape))).pointer.child,
            arena,
            value,
        )),
        .lone => if (value.kind() != .map) {
            var made: Shape = undefined;

            const names = info.field_names;
            const types = info.field_types;
            const attributes = info.field_attrs;

            inline for (names, types, attributes, 0..) |name, Field, attrs, index| {
                @field(made, name) = if (index == 0)
                    try as(Field, arena, value)
                else
                    attrs.defaultValue(Field) orelse return error.Invalid;
            }

            return made;
        },
        .fields => {},
    }

    return fields_as(Shape, arena, value);
}

/// A struct that lies as its one field, holding `held`; a field it keeps to itself is at
/// its default.
fn only(comptime Shape: type, held: @FieldType(Shape, shape_wire.only_field(Shape))) Shape {
    const info = @typeInfo(Shape).@"struct";
    var made: Shape = undefined;

    comptime std.debug.assert(info.field_names.len > 0);

    inline for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
        if (comptime std.mem.eql(u8, name, shape_wire.only_field(Shape))) {
            @field(made, name) = held;
        } else {
            @field(made, name) = comptime attrs.defaultValue(Field).?;
        }
    }

    return made;
}

fn fields_as(comptime Shape: type, arena: std.mem.Allocator, value: Value) Error!Shape {
    const info = @typeInfo(Shape).@"struct";

    std.debug.assert(value.bytes.len > 0);

    const wanted: free_value.Kind = if (info.is_tuple) .list else .map;
    var made: Shape = undefined;

    if (value.kind() != wanted) {
        return error.Invalid;
    }

    const names = info.field_names;
    const types = info.field_types;
    const attributes = info.field_attrs;

    inline for (names, types, attributes, 0..) |name, Field, attrs, index| {
        if (comptime Field == void) {
            @field(made, name) = {};
        } else if (comptime !shape_wire.crosses(Shape, index)) {
            @field(made, name) = comptime attrs.defaultValue(Field).?;
        } else {
            const found = if (info.is_tuple) value.at(index) else value.get(name);

            @field(made, name) = if (found) |held|
                try as(Field, arena, held)
            else
                attrs.defaultValue(Field) orelse return error.Invalid;
        }
    }

    return made;
}

fn pairs_as(comptime Pair: type, arena: std.mem.Allocator, value: Value) Error![]Pair {
    const names = comptime @typeInfo(Pair).@"struct".field_names;

    if (value.kind() != .map) {
        return error.Invalid;
    }

    const made = arena.alloc(Pair, value.count()) catch return error.OutOfMemory;
    var walk = value.entries();

    std.debug.assert(made.len == value.count());

    for (made) |*pair| {
        const entry = walk.next() orelse return error.Invalid;

        @field(pair.*, names[0]) = entry.key;
        @field(pair.*, names[1]) = try as(@FieldType(Pair, names[1]), arena, entry.value);
    }

    return made;
}
