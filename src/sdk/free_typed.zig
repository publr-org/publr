//! A struct to and from a value whose shape comes with the data (`free_value.zig`), with no
//! text in between: `publr.Value.of(arena, line)` and `value.as(Line, arena)`. A struct is a
//! map of its fields, an enum its tag's name, a union `{ alternative: payload }`; a type
//! that says how it lies (`publr_form`, `plugin/shape_wire.zig`) is written the same way
//! JSON writes it: money as `{ PLN: 12300 }`, a reference as its id, a decimal as its text.
const std = @import("std");
const free_value = @import("free_value.zig");
const free_builder = @import("free_builder.zig");
const shape_wire = @import("plugin/shape_wire.zig");
const model_decimal = @import("../model/decimal.zig");

const Value = free_value.Value;
const Builder = free_builder.Builder;

pub const Error = free_builder.Error;

/// `value` as one free-form value, in `arena`.
pub fn of(arena: std.mem.Allocator, value: anytype) Error!Value {
    var builder: Builder = .init(arena);

    try put(&builder, value);

    std.debug.assert(builder.depth == 0);

    return builder.done();
}

/// `value` as a record's document: a field holding nothing is left out of it, as Publr
/// keeps documents.
pub fn document_of(arena: std.mem.Allocator, value: anytype) Error!Value {
    var builder: Builder = .init(arena);

    builder.leaves_nothing_out = true;
    try put(&builder, value);

    std.debug.assert(builder.depth == 0);

    return builder.done();
}

/// `value` written where `builder` stands.
pub fn put(builder: *Builder, value: anytype) Error!void {
    const Shape = @TypeOf(value);

    if (Shape == Value) {
        return builder.put(value);
    }

    // A tree a plugin built for its own use (an outside API's body): written part by part.
    if (Shape == std.json.Value) {
        return @import("free_json.zig").put_tree(builder, value);
    }

    switch (@typeInfo(Shape)) {
        .int, .comptime_int => try builder.int(std.math.cast(i64, value) orelse {
            return error.Invalid;
        }),
        .float, .comptime_float => try builder.float(value),
        .bool => try builder.boolean(value),
        .@"enum", .enum_literal => try builder.text(@tagName(value)),
        .optional => if (value) |payload| {
            try put(builder, payload);
        } else {
            try builder.nothing();
        },
        .pointer => |info| if (info.size == .one) {
            try put(builder, value.*);
        } else if (info.child == u8) {
            try builder.text(value);
        } else {
            try builder.begin_list();

            for (value) |item| {
                try put(builder, item);
            }

            try builder.end();
        },
        .array => try put(builder, @as([]const @typeInfo(Shape).array.child, &value)),
        .@"struct" => try put_struct(builder, value),
        .@"union" => |info| {
            try builder.begin_map();

            inline for (info.field_names, info.field_types) |name, Payload| {
                if (value == @field(info.tag_type.?, name)) {
                    try builder.key(name);

                    if (comptime Payload == void) {
                        try builder.begin_map();
                        try builder.end();
                    } else {
                        try put(builder, @field(value, name));
                    }
                }
            }

            try builder.end();
        },
        .void, .null => try builder.nothing(),
        else => @compileError(@typeName(Shape) ++ " cannot be a free-form value"),
    }
}

fn put_struct(builder: *Builder, value: anytype) Error!void {
    const Shape = @TypeOf(value);
    const info = @typeInfo(Shape).@"struct";
    const form = comptime shape_wire.form_of(Shape);

    const first = comptime if (form == .fields)
        ""
    else if (form == .lone)
        info.field_names[0]
    else
        shape_wire.only_field(Shape);

    std.debug.assert(builder.depth <= free_value.depth_max);

    switch (form) {
        .inner, .lone => return put(builder, @field(value, first)),
        .free => return builder.put(.{
            .bytes = @field(value, first),
        }),
        .json => return builder.put(try @import("free_json.zig").from_text(
            builder.arena,
            @field(value, first),
        )),
        .decimal => {
            var buffer: [model_decimal.text_len_max]u8 = undefined;

            return builder.text(model_decimal.text_of(value.units, Shape.decimal_places, &buffer));
        },
        .keyed => {
            try builder.begin_map();

            for (@field(value, first)) |pair| {
                const names = comptime @typeInfo(@TypeOf(pair)).@"struct".field_names;

                try builder.key(@field(pair, names[0]));
                try put(builder, @field(pair, names[1]));
            }

            return builder.end();
        },
        .fields => {},
    }

    if (info.is_tuple) {
        try builder.begin_list();
    } else {
        try builder.begin_map();
    }

    inline for (info.field_names, info.field_types, 0..) |name, Field, index| {
        // A comptime field holds a value too, as JSON writes it: `.{ .limit = limit_max }`, a
        // query's parameters, makes `limit` one.
        const held = info.field_attrs[index].@"comptime" and Field != void;

        if (comptime held or shape_wire.crosses(Shape, index)) {
            // In a record's document a field holding nothing is left out.
            const left_out = builder.leaves_nothing_out and !info.is_tuple and
                @typeInfo(Field) == .optional and @field(value, name) == null;

            if (!left_out) {
                if (!info.is_tuple) {
                    try builder.key(name);
                }

                try put(builder, @field(value, name));
            }
        }
    }

    try builder.end();
}

pub const as = @import("free_read.zig").as;

test "a struct becomes a value and reads back; money is keyed, a union names its alternative" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const free_json = @import("free_json.zig");
    const Amount = struct {
        currency: []const u8,
        minor: i64,
    };
    const Money = struct {
        amounts: []const Amount = &.{},

        pub const publr_form = .keyed;
    };
    const Line = struct {
        name: []const u8,
        count: u32 = 1,
        kind: enum { item, step } = .item,
        note: ?[]const u8 = null,
        price: Money = .{},
        choice: union(enum) {
            none,
            count: u32,
        } = .none,
        pair: struct {
            u8,
            bool,
        } = .{ 0, false },
    };
    const line: Line = .{
        .name = "Tea",
        .kind = .step,
        .price = .{
            .amounts = &.{.{
                .currency = "PLN",
                .minor = 12300,
            }},
        },
        .choice = .{
            .count = 2,
        },
        .pair = .{ 7, true },
    };
    const value = try of(arena, line);

    try std.testing.expectEqualStrings(
        "{\"name\":\"Tea\",\"count\":1,\"kind\":\"step\",\"note\":null," ++
            "\"price\":{\"PLN\":12300},\"choice\":{\"count\":2},\"pair\":[7,true]}",
        try free_json.text_of(arena, value),
    );

    const back = try as(Line, arena, value);

    try std.testing.expectEqualStrings("Tea", back.name);
    try std.testing.expect(back.kind == .step and back.note == null and back.pair[1]);
    try std.testing.expectEqual(@as(i64, 12300), back.price.amounts[0].minor);
    try std.testing.expectEqual(@as(u32, 2), back.choice.count);

    // What the value lacks takes the field's default; a field with none is missed.
    const partial = try as(Line, arena, try free_json.from_text(arena, "{\"name\":\"A\",\"x\":1}"));

    try std.testing.expectEqual(@as(u32, 1), partial.count);
    try std.testing.expectError(error.Invalid, as(Line, arena, try of(arena, .{
        .count = 2,
    })));
    try std.testing.expectError(error.Invalid, as(u8, arena, try of(arena, 300)));
}

test "a comptime field of a literal is written: a query's parameters" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const limit_max: u32 = 50;
    const made = try of(arena, .{
        .limit = limit_max,
        .name = "store",
    });

    try std.testing.expectEqual(@as(?i64, 50), made.get("limit").?.int());
    try std.testing.expectEqualStrings("store", made.get("name").?.text().?);
}
