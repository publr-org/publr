//! A field's default as JSON, said in a layout's description (`shape_wire.zig`) at build
//! time, for the host to lay out when what it is given leaves the field out. Nothing here
//! runs in a plugin's module.
const std = @import("std");
const shape_wire = @import("shape_wire.zig");
const free_value = @import("../../publr/free_value.zig");
const model_decimal = @import("../../model/decimal.zig");

/// `value` as JSON, the way Publr writes a value of its type.
pub fn json(comptime Shape: type, comptime value: Shape) []const u8 {
    comptime {
        std.debug.assert(@sizeOf(Shape) < 1 << 24);

        return switch (@typeInfo(Shape)) {
            .int => std.fmt.comptimePrint("{d}", .{value}),
            .float => std.fmt.comptimePrint("{e}", .{value}),
            .bool => if (value) "true" else "false",
            .@"enum" => "\"" ++ @tagName(value) ++ "\"",
            .optional => |info| if (value) |payload| json(info.child, payload) else "null",
            .pointer => |info| if (info.size == .one)
                json(info.child, value.*)
            else if (info.child == u8)
                quoted(value)
            else
                list(info.child, value),
            .@"struct" => of_struct(Shape, value),
            .@"union" => |info| for (info.field_names, info.field_types) |name, Payload| {
                if (std.mem.eql(u8, @tagName(value), name)) {
                    break "{\"" ++ name ++ "\":" ++ (if (Payload == void)
                        "{}"
                    else
                        json(Payload, @field(value, name))) ++ "}";
                }
            } else unreachable,
            else => unreachable,
        };
    }
}

fn list(comptime Item: type, comptime values: []const Item) []const u8 {
    comptime {
        std.debug.assert(values.len < shape_wire.nodes_max);

        var out: []const u8 = "[";

        for (values, 0..) |item, index| {
            out = out ++ (if (index > 0) "," else "") ++ json(Item, item);
        }

        return out ++ "]";
    }
}

fn of_struct(comptime Shape: type, comptime value: Shape) []const u8 {
    comptime {
        const info = @typeInfo(Shape).@"struct";
        const form = shape_wire.form_of(Shape);
        const first = if (form == .fields) "" else if (form == .lone)
            info.field_names[0]
        else
            shape_wire.only_field(Shape);

        std.debug.assert(info.field_names.len > 0 or form == .fields);

        switch (form) {
            .inner, .lone => return json(@FieldType(Shape, first), @field(value, first)),
            .decimal => return decimal_text(@field(value, first), Shape.decimal_places),
            .free => return free_text(.{
                .bytes = @field(value, first),
            }),
            .json => return @field(value, first),
            .keyed => {
                var out: []const u8 = "{";

                for (@field(value, first), 0..) |pair, index| {
                    const Pair = @TypeOf(pair);
                    const names = @typeInfo(Pair).@"struct".field_names;

                    out = out ++ (if (index > 0) "," else "") ++ quoted(@field(pair, names[0])) ++
                        ":" ++ json(@FieldType(Pair, names[1]), @field(pair, names[1]));
                }

                return out ++ "}";
            },
            .fields => {},
        }

        var out: []const u8 = if (info.is_tuple) "[" else "{";
        var written: u32 = 0;

        for (info.field_names, info.field_types, 0..) |name, Field, index| {
            if (!shape_wire.crosses(Shape, index)) {
                continue;
            }

            out = out ++ (if (written > 0) "," else "") ++
                (if (info.is_tuple) "" else "\"" ++ name ++ "\":") ++
                json(Field, @field(value, name));
            written += 1;
        }

        return out ++ (if (info.is_tuple) "]" else "}");
    }
}

fn decimal_text(comptime units: i64, comptime places: u8) []const u8 {
    comptime {
        var buffer: [model_decimal.text_len_max]u8 = undefined;
        const text = model_decimal.text_of(units, places, &buffer);
        const kept = text[0..text.len].*;

        std.debug.assert(text.len > 0);

        return "\"" ++ &kept ++ "\"";
    }
}

/// A value whose shape comes with the data, as JSON.
fn free_text(comptime value: free_value.Value) []const u8 {
    comptime {
        std.debug.assert(free_value.valid(value.bytes));

        switch (value.kind()) {
            .null => return "null",
            .true => return "true",
            .false => return "false",
            .int => return std.fmt.comptimePrint("{d}", .{value.int().?}),
            .float => return std.fmt.comptimePrint("{e}", .{value.float().?}),
            .text => return quoted(value.text().?),
            .list => {
                var out: []const u8 = "[";
                var walk = value.items();

                while (walk.next()) |item| {
                    out = out ++ (if (out.len > 1) "," else "") ++ free_text(item);
                }

                return out ++ "]";
            },
            .map => {
                var out: []const u8 = "{";
                var walk = value.entries();

                while (walk.next()) |entry| {
                    out = out ++ (if (out.len > 1) "," else "") ++ quoted(entry.key) ++ ":" ++
                        free_text(entry.value);
                }

                return out ++ "}";
            },
        }
    }
}

/// A text as a JSON string, at build time.
fn quoted(comptime text: []const u8) []const u8 {
    comptime {
        std.debug.assert(text.len < 1 << 16);

        var out: []const u8 = "\"";

        for (text) |byte| {
            out = out ++ switch (byte) {
                '"' => "\\\"",
                '\\' => "\\\\",
                '\n' => "\\n",
                else => &[_]u8{byte},
            };
        }

        return out ++ "\"";
    }
}

test "a default is said as Publr writes a value of its type" {
    const Pair = struct {
        key: []const u8,
        count: u32,
    };
    const Keyed = struct {
        pairs: []const Pair = &.{},

        pub const publr_form = .keyed;
    };
    const Choice = union(enum) {
        none,
        count: u32,
    };
    const Line = struct {
        name: []const u8 = "a\"b",
        tags: []const []const u8 = &.{ "x", "y" },
        pair: struct {
            u8,
            bool,
        } = .{ 1, true },
        keyed: Keyed = .{
            .pairs = &.{.{
                .key = "PLN",
                .count = 3,
            }},
        },
        choice: Choice = .{
            .count = 2,
        },
        other: Choice = .none,
    };

    try std.testing.expectEqualStrings(
        "{\"name\":\"a\\\"b\",\"tags\":[\"x\",\"y\"],\"pair\":[1,true]," ++
            "\"keyed\":{\"PLN\":3},\"choice\":{\"count\":2},\"other\":{\"none\":{}}}",
        comptime json(Line, .{}),
    );
}
