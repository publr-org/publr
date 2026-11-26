//! A value whose shape comes with the data (`free_value.zig`) to and from JSON, for where
//! Publr keeps or sends JSON: storage, the log, the outer edge. A plugin's module never needs
//! this file to talk to Publr.
const std = @import("std");
const free_value = @import("../publr/free_value.zig");
const free_builder = @import("../publr/free_builder.zig");

const Value = free_value.Value;
const Builder = free_builder.Builder;

pub const Error = free_builder.Error;

/// `value` as JSON. A value that is not well made is refused, never half written as one.
pub fn write(writer: *std.Io.Writer, value: Value) (Error || error{WriteFailed})!void {
    if (!free_value.valid(value.bytes)) {
        return error.Invalid;
    }

    std.debug.assert(value.bytes.len > 0);

    return write_checked(writer, value);
}

/// One text or number as JSON writes it.
fn encoded(writer: *std.Io.Writer, value: anytype) error{WriteFailed}!void {
    var encoder: std.json.Stringify = .{
        .writer = writer,
    };

    try encoder.write(value);
}

fn write_checked(writer: *std.Io.Writer, value: Value) error{WriteFailed}!void {
    std.debug.assert(free_value.complete(value.bytes));

    switch (value.kind()) {
        .null => try writer.writeAll("null"),
        .true => try writer.writeAll("true"),
        .false => try writer.writeAll("false"),
        .int => try writer.print("{d}", .{value.int().?}),
        .float => try encoded(writer, value.float().?),
        .text => try encoded(writer, value.text().?),
        .list => {
            var walk = value.items();
            var first = true;

            try writer.writeByte('[');

            while (walk.next()) |item| : (first = false) {
                if (!first) {
                    try writer.writeByte(',');
                }

                try write_checked(writer, item);
            }

            try writer.writeByte(']');
        },
        .map => {
            var walk = value.entries();
            var first = true;

            try writer.writeByte('{');

            while (walk.next()) |entry| : (first = false) {
                if (!first) {
                    try writer.writeByte(',');
                }

                try encoded(writer, entry.key);
                try writer.writeByte(':');
                try write_checked(writer, entry.value);
            }

            try writer.writeByte('}');
        },
    }
}

/// `value` as JSON text, in `arena`.
pub fn text_of(arena: std.mem.Allocator, value: Value) Error![]const u8 {
    var output: std.Io.Writer.Allocating = .init(arena);

    write(&output.writer, value) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |other| return other,
    };

    std.debug.assert(output.written().len > 0);

    return output.written();
}

/// The JSON `text` as a value, in `arena`.
pub fn from_text(arena: std.mem.Allocator, text: []const u8) Error!Value {
    const tree = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| {
        return if (err == error.OutOfMemory) error.OutOfMemory else error.Invalid;
    };

    std.debug.assert(text.len > 0);

    return from_tree(arena, tree);
}

pub fn from_tree(arena: std.mem.Allocator, tree: std.json.Value) Error!Value {
    var builder: Builder = .init(arena);

    try put_tree(&builder, tree);

    std.debug.assert(builder.depth == 0);

    return builder.done();
}

/// `tree` written where `builder` stands.
pub fn put_tree(builder: *Builder, tree: std.json.Value) Error!void {
    std.debug.assert(builder.depth <= free_value.depth_max);

    switch (tree) {
        .null => try builder.nothing(),
        .bool => |held| try builder.boolean(held),
        .integer => |held| try builder.int(held),
        .float => |held| try builder.float(held),
        // A whole number too large for 64 bits keeps its size, not its last digits.
        .number_string => |held| try builder.float(std.fmt.parseFloat(f64, held) catch {
            return error.Invalid;
        }),
        .string => |held| try builder.text(held),
        .array => |held| {
            try builder.begin_list();

            for (held.items) |item| {
                try put_tree(builder, item);
            }

            try builder.end();
        },
        .object => |held| {
            try builder.begin_map();

            for (held.keys(), held.values()) |key, item| {
                try builder.key(key);
                try put_tree(builder, item);
            }

            try builder.end();
        },
    }
}

/// `value` as a tree, in `arena`; its texts stay where the value lies.
pub fn tree_of(arena: std.mem.Allocator, value: Value) Error!std.json.Value {
    if (!free_value.valid(value.bytes)) {
        return error.Invalid;
    }

    std.debug.assert(value.bytes.len > 0);

    return tree_checked(arena, value);
}

fn tree_checked(arena: std.mem.Allocator, value: Value) error{OutOfMemory}!std.json.Value {
    std.debug.assert(free_value.complete(value.bytes));

    switch (value.kind()) {
        .null => return .null,
        .true, .false => return .{
            .bool = value.boolean().?,
        },
        .int => return .{
            .integer = value.int().?,
        },
        .float => return .{
            .float = value.float().?,
        },
        .text => return .{
            .string = value.text().?,
        },
        .list => {
            var list: std.json.Array = .init(arena);
            var walk = value.items();

            try list.ensureTotalCapacity(value.count());

            while (walk.next()) |item| {
                list.appendAssumeCapacity(try tree_checked(arena, item));
            }

            return .{
                .array = list,
            };
        },
        .map => {
            var map: std.json.ObjectMap = .empty;
            var walk = value.entries();

            while (walk.next()) |entry| {
                try map.put(arena, entry.key, try tree_checked(arena, entry.value));
            }

            return .{
                .object = map,
            };
        },
    }
}

test "JSON becomes a value and comes back the same" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = "{\"PLN\":12300,\"tags\":[\"a\\\"b\",true,null,1.5,[],{}]," ++
        "\"deep\":{\"on\":false}}";
    const value = try from_text(arena, text);

    try std.testing.expect(free_value.valid(value.bytes));
    try std.testing.expectEqualStrings(text, try text_of(arena, value));
    try std.testing.expectEqual(@as(?bool, false), value.get("deep").?.get("on").?.boolean());

    const tree = try tree_of(arena, value);

    try std.testing.expectEqual(@as(i64, 12300), tree.object.get("PLN").?.integer);
    try std.testing.expectEqualStrings(text, try text_of(arena, try from_tree(arena, tree)));

    // What is no JSON, and what is no value, are refused.
    try std.testing.expectError(error.Invalid, from_text(arena, "{\"a\":"));
    try std.testing.expectError(error.Invalid, text_of(arena, .{
        .bytes = &.{ 5, 9, 0, 0, 0, 'a' },
    }));
    try std.testing.expectError(error.Invalid, tree_of(arena, .{
        .bytes = &.{ 6, 1, 0, 0, 0, 2, 0, 0, 0, 0 },
    }));
}
