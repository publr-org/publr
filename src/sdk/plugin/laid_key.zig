//! What a value says, as bytes that are the same for the same value and differ for another:
//! each number as it lies, each text and list behind its length, an optional behind whether
//! it is there. What a read is remembered by (`read_memo.zig`, `mod_reads.zig`): the value
//! is walked once where it lies, no names are written, nothing is built to be read back.
const std = @import("std");
const shape_wire = @import("shape_wire.zig");

pub const Error = error{OutOfMemory};

/// The key of `value`, in `arena`.
pub fn of(arena: std.mem.Allocator, value: anytype) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;

    try put(&out, arena, value);

    std.debug.assert(out.items.len <= std.math.maxInt(u32));

    return out.items;
}

fn put(out: *std.ArrayList(u8), arena: std.mem.Allocator, value: anytype) Error!void {
    const Shape = @TypeOf(value);

    switch (@typeInfo(Shape)) {
        .void, .null => {},
        .bool => try out.append(arena, @intFromBool(value)),
        .int, .comptime_int => try number(out, arena, @as(i128, value)),
        .float, .comptime_float => try number(out, arena, @as(u64, @bitCast(@as(f64, value)))),
        .@"enum" => try number(out, arena, @as(i128, @backingInt(value))),
        .enum_literal => try text(out, arena, @tagName(value)),
        .optional => if (value) |payload| {
            try out.append(arena, 1);
            try put(out, arena, payload);
        } else {
            try out.append(arena, 0);
        },
        .pointer => |info| if (info.size == .one) {
            try put(out, arena, value.*);
        } else if (info.child == u8) {
            try text(out, arena, value);
        } else {
            try number(out, arena, value.len);

            for (value) |item| {
                try put(out, arena, item);
            }
        },
        .array => for (value) |item| {
            try put(out, arena, item);
        },
        .@"struct" => |info| inline for (info.field_names, 0..) |name, index| {
            const held = info.field_attrs[index].@"comptime" and info.field_types[index] != void;

            if (comptime held or shape_wire.crosses(Shape, index)) {
                try put(out, arena, @field(value, name));
            }
        },
        .@"union" => |info| inline for (info.field_names, 0..) |name, index| {
            if (value == @field(info.tag_type.?, name)) {
                try out.append(arena, index);

                if (comptime info.field_types[index] != void) {
                    try put(out, arena, @field(value, name));
                }
            }
        },
        else => @compileError(@typeName(Shape) ++ " cannot be what a read is remembered by"),
    }
}

/// A whole number in eight bytes: every int a value hands over fits 64 bits.
fn number(out: *std.ArrayList(u8), arena: std.mem.Allocator, value: i128) Error!void {
    var raw: [8]u8 = undefined;

    std.debug.assert(value >= std.math.minInt(i64) and value <= std.math.maxInt(u64));

    std.mem.writeInt(u64, &raw, @truncate(@as(u128, @bitCast(value))), .little);
    try out.appendSlice(arena, &raw);
}

fn text(out: *std.ArrayList(u8), arena: std.mem.Allocator, value: []const u8) Error!void {
    std.debug.assert(value.len <= std.math.maxInt(u32));

    try number(out, arena, value.len);
    try out.appendSlice(arena, value);
}

test "the same value has the same key; another value another, whatever its texts hold" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Asked = struct {
        kind: []const u8,
        ids: []const []const u8 = &.{},
        limit: ?u32 = null,
        oldest: bool = false,
        purpose: enum { delivery, edit } = .delivery,
    };
    const first = try of(arena, Asked{
        .kind = "orders.line",
        .ids = &.{ "a", "bc" },
    });
    const same = try of(arena, Asked{
        .kind = "orders.line",
        .ids = &.{ "a", "bc" },
    });
    const split = try of(arena, Asked{
        .kind = "orders.line",
        .ids = &.{ "ab", "c" },
    });
    const limited = try of(arena, Asked{
        .kind = "orders.line",
        .ids = &.{ "a", "bc" },
        .limit = 0,
    });
    const edited = try of(arena, Asked{
        .kind = "orders.line",
        .ids = &.{ "a", "bc" },
        .purpose = .edit,
    });

    try std.testing.expectEqualSlices(u8, first, same);
    try std.testing.expect(!std.mem.eql(u8, first, split));
    try std.testing.expect(!std.mem.eql(u8, first, limited));
    try std.testing.expect(!std.mem.eql(u8, first, edited));
    try std.testing.expect(!std.mem.eql(u8, limited, edited));
}
