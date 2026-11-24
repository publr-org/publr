//! How each kind of type is said in a layout's description (`shape_wire.zig`), at build
//! time: nothing here runs in a plugin's module.
const std = @import("std");
const shape_wire = @import("shape_wire.zig");
const shape_default = @import("shape_default.zig");

/// `Shape` described inside the structs and unions `inside`; `addressed` when it lies at an
/// address of its own (a list's item, a pointer's target, a union's payload), where alone a
/// type may hold itself.
pub fn said(
    comptime Shape: type,
    comptime inside: []const type,
    comptime addressed: bool,
) []const u8 {
    comptime {
        std.debug.assert(inside.len < shape_wire.nodes_max);

        return switch (@typeInfo(Shape)) {
            .int => |info| if (info.bits > 64)
                @compileError(@typeName(Shape) ++ ": an int handed over is 64 bits at most")
            else
                &[_]u8{ 'i', @sizeOf(Shape), @intFromBool(info.signedness == .signed) },
            .float => &[_]u8{ 'f', @sizeOf(Shape) },
            .bool => "b",
            .@"enum" => said_enum(Shape),
            .optional => |info| said_optional(info.child, inside),
            .pointer => |info| said_pointer(Shape, info, inside),
            .@"struct", .@"union" => for (inside, 0..) |Outer, index| {
                if (Outer == Shape) {
                    if (!addressed) {
                        @compileError(@typeName(Shape) ++ " holds itself in an optional: " ++
                            "say it as a list or a pointer");
                    }

                    break &[_]u8{ 'r', inside.len - index };
                }
            } else if (@typeInfo(Shape) == .@"union")
                said_union(Shape, inside)
            else
                said_struct(Shape, inside),
            else => @compileError(@typeName(Shape) ++ " cannot be handed to Publr or to " ++
                "another plugin: use numbers, texts, enums, optionals, lists, structs, " ++
                "tagged unions and `publr.Value`"),
        };
    }
}

fn said_enum(comptime Shape: type) []const u8 {
    comptime {
        const info = @typeInfo(Shape).@"enum";

        std.debug.assert(@sizeOf(Shape) <= 8);

        const own = std.meta.hasFn(Shape, "jsonParse") or std.meta.hasFn(Shape, "jsonStringify");

        if (info.mode == .nonexhaustive or own) {
            @compileError(@typeName(Shape) ++ ": an enum handed over is its tags by name, " ++
                "every one listed, with no JSON of its own");
        }

        var out: []const u8 = &[_]u8{ 'e', @sizeOf(Shape) } ++
            shape_wire.word(info.field_names.len);

        for (info.field_names) |name| {
            var value: [8]u8 = undefined;

            std.mem.writeInt(i64, &value, @backingInt(@field(Shape, name)), .little);

            const kept = value;

            out = out ++ &[_]u8{name.len} ++ name ++ &kept;
        }

        return out;
    }
}

/// An optional is its payload, then a byte saying it is there; a slice's or a pointer's is
/// the payload alone, its address zero for none.
fn said_optional(comptime Payload: type, comptime inside: []const type) []const u8 {
    comptime {
        const niche = @sizeOf(?Payload) == @sizeOf(Payload);

        std.debug.assert(!niche or @typeInfo(Payload) == .pointer);

        return "n" ++ shape_wire.word(@sizeOf(Payload)) ++ &[_]u8{@intFromBool(niche)} ++
            said(Payload, inside, false);
    }
}

fn said_pointer(
    comptime Shape: type,
    comptime info: std.builtin.Type.Pointer,
    comptime inside: []const type,
) []const u8 {
    comptime {
        std.debug.assert(@sizeOf(Shape) >= 4);

        if (info.sentinel() != null or info.size == .many or info.size == .c) {
            @compileError(@typeName(Shape) ++ ": a list handed over is a slice with no " ++
                "sentinel, a pointer is to one value");
        }

        if (info.size == .slice and info.child == u8) {
            return "s";
        }

        const sizes = shape_wire.word(@sizeOf(info.child)) ++ shape_wire.word(@alignOf(info.child));

        if (info.size == .one) {
            return "p" ++ sizes ++ said(info.child, inside, true);
        }

        return "l\x00" ++ sizes ++ said(info.child, inside, true);
    }
}

fn said_union(comptime Shape: type, comptime inside: []const type) []const u8 {
    comptime {
        const info = @typeInfo(Shape).@"union";

        if (info.tag_type == null or std.meta.hasFn(Shape, "jsonParse")) {
            @compileError(@typeName(Shape) ++ ": a union handed over is tagged " ++
                "(`union(enum)`), with no JSON of its own");
        }

        std.debug.assert(info.field_names.len > 0);

        var out: []const u8 = "u" ++ shape_wire.word(info.field_names.len);

        for (info.field_names, info.field_types) |name, Payload| {
            const payload = if (Payload == void)
                "o\x00" ++ shape_wire.word(0) ++ shape_wire.word(0)
            else
                said(Payload, inside ++ &[_]type{Shape}, true);

            out = out ++ &[_]u8{name.len} ++ name ++ shape_wire.word(@sizeOf(Payload)) ++
                shape_wire.word(@max(@alignOf(Payload), 1)) ++ payload;
        }

        return out;
    }
}

fn said_struct(comptime Shape: type, comptime inside: []const type) []const u8 {
    comptime {
        const info = @typeInfo(Shape).@"struct";
        const form = shape_wire.form_of(Shape);

        if (form != .fields and form != .lone) {
            return said_formed(Shape, form, inside);
        }

        const deeper = inside ++ &[_]type{Shape};

        var out: []const u8 = "";
        var count: u32 = 0;

        const names = info.field_names;
        const types = info.field_types;
        const attributes = info.field_attrs;

        for (names, types, attributes, 0..) |name, Field, attrs, index| {
            if (!shape_wire.crosses(Shape, index)) {
                continue;
            }

            const default = if (attrs.defaultValue(Field)) |value|
                shape_default.json(Field, value)
            else
                "";

            out = out ++ &[_]u8{name.len} ++ name ++ shape_wire.word(@offsetOf(Shape, name)) ++
                shape_wire.word(default.len) ++ default ++ said(Field, deeper, false);
            count += 1;
        }

        const tuple: u8 = if (info.is_tuple) shape_wire.form_tuple else 0;
        const flags = tuple | (if (form == .lone) shape_wire.form_lone else 0);

        std.debug.assert(form != .lone or count > 0);

        const head = "o" ++ &[_]u8{flags} ++ shape_wire.word(@sizeOf(Shape));

        return head ++ shape_wire.word(count) ++ out;
    }
}

/// A struct that lies as its one field.
fn said_formed(
    comptime Shape: type,
    comptime form: shape_wire.Form,
    comptime inside: []const type,
) []const u8 {
    comptime {
        const name = shape_wire.only_field(Shape);
        const Field = @FieldType(Shape, name);

        if (@offsetOf(Shape, name) != 0) {
            @compileError(@typeName(Shape) ++ ": the field it lies as must come first");
        }

        std.debug.assert(@sizeOf(Shape) >= @sizeOf(Field));

        switch (form) {
            .inner => return said(Field, inside, false),
            .decimal => {
                std.debug.assert(Field == i64);

                return &[_]u8{ 'd', Shape.decimal_places };
            },
            .free, .json => {
                std.debug.assert(Field == []const u8);

                return "v";
            },
            .keyed => {
                const Pair = @typeInfo(Field).pointer.child;
                const pair = @typeInfo(Pair).@"struct";

                if (pair.field_names.len != 2 or pair.field_types[0] != []const u8) {
                    @compileError(@typeName(Shape) ++ ": a keyed list's item is its key, a " ++
                        "text, then its value");
                }

                const room = shape_wire.word(@sizeOf(Pair)) ++ shape_wire.word(@alignOf(Pair));

                return "l\x01" ++ room ++ said(Pair, inside, true);
            },
            .fields, .lone => unreachable,
        }
    }
}
