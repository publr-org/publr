const std = @import("std");
const field = @import("field.zig");
const kinds = @import("kinds.zig");

const Kind = kinds.Kind;
const Value = std.json.Value;

pub const Error = error{ NotConvertible, DataDoesNotFit, OutOfMemory };

pub const allowed = kinds.convertible;

pub fn convert(
    known: []const Kind,
    arena: std.mem.Allocator,
    from: field.Def,
    to: field.Def,
    value: Value,
) Error!Value {
    if (!allowed(known, from.kind, to.kind)) {
        return error.NotConvertible;
    }

    std.debug.assert(std.mem.eql(u8, from.name, to.name));

    if (value == .null) {
        return .null;
    }

    if (from.many and !to.many) {
        if (value != .array) {
            return value;
        }

        if (value.array.items.len > 1) {
            return error.DataDoesNotFit;
        }

        return if (value.array.items.len == 1) value.array.items[0] else .null;
    }

    if (!from.many and to.many) {
        var array = std.json.Array.init(arena);
        array.append(value) catch return error.OutOfMemory;

        return .{ .array = array };
    }

    return convert_scalar(known, arena, from, to, value);
}

/// The value in the target's storage shape, then through the target kind's own check:
/// a value fits a kind exactly when that kind would accept it as new.
fn convert_scalar(
    known: []const Kind,
    arena: std.mem.Allocator,
    from: field.Def,
    to: field.Def,
    value: Value,
) Error!Value {
    if (!allowed(known, from.kind, to.kind)) {
        return error.NotConvertible;
    }

    std.debug.assert(field.is_leaf(to.kind) or std.mem.eql(u8, from.kind, to.kind));

    if (std.mem.eql(u8, from.kind, to.kind)) {
        return value;
    }

    const target = kinds.find(known, to.kind) orelse return error.NotConvertible;
    const shaped = try coerce(arena, target.storage, value);

    if (target.check) |check| {
        var problems: field.Problems = .{};

        check(to, shaped, to.name, &problems);

        if (!problems.is_empty()) {
            return error.DataDoesNotFit;
        }
    }

    return shaped;
}

fn coerce(arena: std.mem.Allocator, storage: kinds.Storage, value: Value) Error!Value {
    std.debug.assert(value != .null);
    std.debug.assert(@intFromEnum(storage) <= 6);

    if (value == .float and !std.math.isFinite(value.float)) {
        return error.DataDoesNotFit;
    }

    return switch (storage) {
        .int => switch (value) {
            .string => |text| .{
                .integer = std.fmt.parseInt(i64, text, 10) catch return error.DataDoesNotFit,
            },
            .float => |number| if (std.math.isFinite(number) and number == @trunc(number) and
                number >= -0x1p63 and number < 0x1p63)
                .{ .integer = @intFromFloat(number) }
            else
                error.DataDoesNotFit,
            .integer => value,
            else => error.DataDoesNotFit,
        },
        .real => switch (value) {
            .string => |text| .{
                .float = try finite_number(text),
            },
            .integer => |number| .{ .float = @floatFromInt(number) },
            .float => value,
            else => error.DataDoesNotFit,
        },
        .text, .long => switch (value) {
            .string => value,
            .integer => |number| .{ .string = try print(arena, "{d}", .{number}) },
            .float => |number| .{ .string = try print(arena, "{d}", .{number}) },
            .bool => |flag| .{ .string = if (flag) "true" else "false" },
            else => error.DataDoesNotFit,
        },
        .ref, .bool, .none => error.NotConvertible,
    };
}

fn print(arena: std.mem.Allocator, comptime format: []const u8, args: anytype) Error![]const u8 {
    std.debug.assert(format.len > 0);
    std.debug.assert(std.mem.indexOfScalar(u8, format, '{') != null);

    return std.fmt.allocPrint(arena, format, args) catch error.OutOfMemory;
}

test "conversion table: widening allowed, shape changes refused" {
    try std.testing.expect(allowed(&kinds.core, "string", "text"));
    try std.testing.expect(allowed(&kinds.core, "string", "integer"));
    try std.testing.expect(allowed(&kinds.core, "integer", "number"));
    try std.testing.expect(allowed(&kinds.core, "datetime", "integer"));
    try std.testing.expect(!allowed(&kinds.core, "text", "string"));
    try std.testing.expect(!allowed(&kinds.core, "reference", "string"));
    try std.testing.expect(!allowed(&kinds.core, "string", "reference"));
    try std.testing.expect(!allowed(&kinds.core, "repeater", "group"));
}

test "values convert when they fit and are refused when they do not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const known = &kinds.core;
    const text: field.Def = .{ .name = "n", .label = "N", .kind = "string" };
    const integer: field.Def = .{ .name = "n", .label = "N", .kind = "integer" };
    const select: field.Def = .{
        .name = "n",
        .label = "N",
        .kind = "select",
        .options = .{ .choices = &.{"a"} },
    };
    const slug: field.Def = .{ .name = "n", .label = "N", .kind = "slug" };

    const forty_two = try convert(known, arena, text, integer, .{ .string = "42" });
    try std.testing.expectEqual(@as(i64, 42), forty_two.integer);
    try std.testing.expectError(
        error.DataDoesNotFit,
        convert(known, arena, text, integer, .{ .string = "x" }),
    );
    try std.testing.expectError(
        error.DataDoesNotFit,
        convert(known, arena, text, select, .{ .string = "b" }),
    );
    try std.testing.expectError(
        error.DataDoesNotFit,
        convert(known, arena, text, slug, .{ .string = "Not A Slug" }),
    );

    const as_text = try convert(known, arena, integer, text, .{ .integer = 7 });
    try std.testing.expectEqualStrings("7", as_text.string);

    const one: field.Def = .{ .name = "r", .label = "R", .kind = "reference" };
    const many: field.Def = .{ .name = "r", .label = "R", .kind = "reference", .many = true };
    const wrapped = try convert(known, arena, one, many, .{ .string = "t1" });
    try std.testing.expectEqual(@as(usize, 1), wrapped.array.items.len);

    var two = std.json.Array.init(arena);
    try two.append(.{ .string = "a" });
    try two.append(.{ .string = "b" });
    try std.testing.expectError(
        error.DataDoesNotFit,
        convert(known, arena, many, one, .{ .array = two }),
    );
}

test "numeric conversion refuses out-of-range floats and preserves absent values" {
    const number: field.Def = .{ .name = "n", .label = "N", .kind = "number" };
    const integer: field.Def = .{ .name = "n", .label = "N", .kind = "integer" };

    for ([_]f64{ 0x1p63, -0x1p64, std.math.inf(f64), std.math.nan(f64), 1.5 }) |value| {
        try std.testing.expectError(
            error.DataDoesNotFit,
            coerce(
                std.testing.allocator,
                .int,
                .{
                    .float = value,
                },
            ),
        );
    }

    try std.testing.expectEqual(
        std.math.minInt(i64),
        (try coerce(
            std.testing.allocator,
            .int,
            .{
                .float = -0x1p63,
            },
        )).integer,
    );
    try std.testing.expectEqual(
        @as(
            i64,
            42,
        ),
        (try coerce(
            std.testing.allocator,
            .int,
            .{
                .float = 42,
            },
        )).integer,
    );
    try std.testing.expect((try convert(
        &kinds.core,
        std.testing.allocator,
        number,
        integer,
        .null,
    )) == .null);
}

fn finite_number(text: []const u8) Error!f64 {
    const number = std.fmt.parseFloat(f64, text) catch return error.DataDoesNotFit;

    if (!std.math.isFinite(number)) {
        return error.DataDoesNotFit;
    }

    std.debug.assert(std.math.isFinite(number));
    return number;
}
