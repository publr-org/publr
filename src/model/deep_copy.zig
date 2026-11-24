//! A value copied into another allocator with everything it points at: what a loop keeps
//! of an item worked on in a scratch before the scratch is given back.
const std = @import("std");

pub const Error = error{OutOfMemory};

/// `value` and every slice, pointer and text it reaches, copied into `arena`.
pub fn copy(comptime Value: type, arena: std.mem.Allocator, value: Value) Error!Value {
    comptime std.debug.assert(@typeInfo(Value) != .@"fn");

    switch (@typeInfo(Value)) {
        .pointer => |pointer| switch (pointer.size) {
            .slice => {
                if (comptime plain(pointer.child)) {
                    return arena.dupe(pointer.child, value);
                }

                const items = try arena.alloc(pointer.child, value.len);

                for (value, items) |item, *target| {
                    target.* = try copy(pointer.child, arena, item);
                }

                return items;
            },
            .one => {
                const item = try arena.create(pointer.child);

                item.* = try copy(pointer.child, arena, value.*);

                return item;
            },
            else => @compileError("no copy of " ++ @typeName(Value)),
        },
        .@"struct" => |shape| {
            var copied: Value = value;

            inline for (shape.field_names, shape.field_types) |name, Field| {
                @field(copied, name) = try copy(Field, arena, @field(value, name));
            }

            return copied;
        },
        .optional => |optional| {
            const present = value orelse return null;

            return try copy(optional.child, arena, present);
        },
        .array => |array| {
            var copied: Value = undefined;

            for (value, &copied) |item, *target| {
                target.* = try copy(array.child, arena, item);
            }

            return copied;
        },
        .@"union" => switch (value) {
            inline else => |held, tag| {
                const Field = @FieldType(Value, @tagName(tag));

                return @unionInit(Value, @tagName(tag), try copy(Field, arena, held));
            },
        },
        else => return value,
    }
}

/// Whether a value holds nothing it points at.
fn plain(comptime Value: type) bool {
    comptime std.debug.assert(@typeInfo(Value) != .@"fn");

    return switch (@typeInfo(Value)) {
        .int, .float, .bool, .@"enum" => true,
        else => false,
    };
}

const Item = struct {
    name: []const u8,
    tags: []const []const u8 = &.{},
    inner: ?*const Item = null,
    kind: union(enum) {
        none,
        text: []const u8,
    } = .none,
};

test "a copy keeps nothing of where it came from" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var scratch_state = std.heap.ArenaAllocator.init(std.testing.allocator);

    const scratch = scratch_state.allocator();
    const inner = try scratch.create(Item);

    inner.* = .{
        .name = try scratch.dupe(u8, "inner"),
    };

    const items = try scratch.alloc(Item, 1);

    items[0] = .{
        .name = try scratch.dupe(u8, "outer"),
        .tags = try scratch.dupe([]const u8, &.{try scratch.dupe(u8, "a")}),
        .inner = inner,
        .kind = .{
            .text = try scratch.dupe(u8, "t"),
        },
    };

    const kept = try copy([]const Item, arena_state.allocator(), items);

    scratch_state.deinit();

    try std.testing.expectEqualStrings("outer", kept[0].name);
    try std.testing.expectEqualStrings("a", kept[0].tags[0]);
    try std.testing.expectEqualStrings("inner", kept[0].inner.?.name);
    try std.testing.expectEqualStrings("t", kept[0].kind.text);
}
