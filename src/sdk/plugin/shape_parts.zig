//! The unions of a value beside its block (`shape_wire.zig`): one entry each, in the order a
//! walk of the value meets them (a struct's fields as declared, a list's items in turn, a
//! union's entry before what its payload holds). The guest writes them for what it hands
//! over (`table_of`) and builds its unions from what the host laid out (`fill`).
const std = @import("std");
const shape_wire = @import("shape_wire.zig");

const Entry = shape_wire.Entry;

pub const Error = error{ Invalid, OutOfMemory };

/// Whether a walk of `Shape` meets a union.
pub fn has_choice(comptime Shape: type) bool {
    comptime {
        @setEvalBranchQuota(shape_wire.nodes_max * shape_wire.steps_per_node);

        return meets(Shape, &.{});
    }
}

fn meets(comptime Shape: type, comptime inside: []const type) bool {
    comptime {
        std.debug.assert(inside.len < shape_wire.nodes_max);

        // Met again: what it holds is found by the walk already under way.
        for (inside) |Outer| {
            if (Outer == Shape) {
                return false;
            }
        }

        return switch (@typeInfo(Shape)) {
            .@"union" => true,
            .optional => |info| meets(info.child, inside),
            .pointer => |info| info.child != u8 and meets(info.child, inside),
            .@"struct" => |info| for (info.field_types, 0..) |Field, index| {
                const carried = shape_wire.crosses(Shape, index);

                if (carried and meets(Field, inside ++ &[_]type{Shape})) {
                    break true;
                }
            } else false,
            else => false,
        };
    }
}

/// Each union of `value`, in walk order: where its payload lies and which alternative it is.
pub fn table_of(
    comptime Shape: type,
    arena: std.mem.Allocator,
    value: *const Shape,
    table: *std.ArrayList(Entry),
) Error!void {
    if (comptime !has_choice(Shape)) {
        return;
    }

    switch (@typeInfo(Shape)) {
        .optional => |info| if (value.*) |*payload| {
            try table_of(info.child, arena, payload, table);
        },
        .pointer => |info| if (info.size == .one) {
            try table_of(info.child, arena, value.*, table);
        } else for (value.*) |*item| {
            try table_of(info.child, arena, item, table);
        },
        .@"struct" => |info| inline for (info.field_names, info.field_types, 0..) |
            name,
            Field,
            index,
        | {
            if (comptime shape_wire.crosses(Shape, index)) {
                try table_of(Field, arena, &@field(value.*, name), table);
            }
        },
        .@"union" => |info| inline for (info.field_names, info.field_types, 0..) |
            name,
            Payload,
            index,
        | {
            if (value.* == @field(info.tag_type.?, name)) {
                const lies = comptime @sizeOf(Payload) > 0;

                table.append(arena, .{
                    .ptr = if (lies) @truncate(@intFromPtr(&@field(value.*, name))) else 0,
                    .len = index,
                }) catch return error.OutOfMemory;

                if (comptime Payload != void) {
                    try table_of(Payload, arena, &@field(value.*, name), table);
                }
            }
        },
        else => unreachable,
    }
}

/// Builds each union of `place` from the side table the host laid out beside it, in walk
/// order: the payload is where the entry says, already as this build lays it out.
pub fn fill(comptime Shape: type, place: *Shape, table: []const Entry, next: *u32) Error!void {
    if (comptime !has_choice(Shape)) {
        return;
    }

    std.debug.assert(next.* <= table.len);

    switch (@typeInfo(Shape)) {
        .optional => |info| if (place.*) |*payload| {
            try fill(info.child, payload, table, next);
        },
        .pointer => |info| if (info.size == .one) {
            try fill(info.child, @constCast(place.*), table, next);
        } else for (@constCast(place.*)) |*item| {
            try fill(info.child, item, table, next);
        },
        .@"struct" => |info| inline for (info.field_names, info.field_types, 0..) |
            name,
            Field,
            index,
        | {
            if (comptime shape_wire.crosses(Shape, index)) {
                try fill(Field, &@field(place.*, name), table, next);
            }
        },
        .@"union" => try fill_union(Shape, place, table, next),
        else => unreachable,
    }
}

fn fill_union(comptime Shape: type, place: *Shape, table: []const Entry, next: *u32) Error!void {
    const info = @typeInfo(Shape).@"union";

    if (next.* >= table.len) {
        return error.Invalid;
    }

    const entry = table[next.*];

    std.debug.assert(info.field_names.len > 0);

    next.* += 1;

    inline for (info.field_names, info.field_types, 0..) |name, Payload, index| {
        if (entry.len == index) {
            if (comptime @sizeOf(Payload) == 0) {
                place.* = @unionInit(Shape, name, undefined);
                return;
            }

            if (entry.ptr == 0 or entry.ptr % @alignOf(Payload) != 0) {
                return error.Invalid;
            }

            const payload: *Payload = @ptrFromInt(entry.ptr);

            try fill(Payload, payload, table, next);
            place.* = @unionInit(Shape, name, payload.*);

            return;
        }
    }

    return error.Invalid;
}

test "a value's unions are listed in walk order and built back from the list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Choice = union(enum) {
        none,
        count: u32,
        pair: struct {
            low: u16,
            high: u16,
        },
    };
    const Line = struct {
        name: u8,
        first: Choice,
        rest: ?Choice,
    };
    const Plain = struct {
        name: []const u8,
    };
    const sent: Line = .{
        .name = 7,
        .first = .{
            .pair = .{
                .low = 1,
                .high = 2,
            },
        },
        .rest = .none,
    };
    var table: std.ArrayList(Entry) = .empty;

    try std.testing.expect(comptime has_choice(Line) and !has_choice(Plain));
    try table_of(Line, arena, &sent, &table);
    try std.testing.expectEqual(@as(usize, 2), table.items.len);
    try std.testing.expectEqual(@as(u32, 2), table.items[0].len);
    try std.testing.expectEqual(@as(u32, 0), table.items[1].len);
    try std.testing.expectEqual(@as(u32, 0), table.items[1].ptr);
}
