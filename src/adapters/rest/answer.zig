//! What `/api/<operation>` answers: the operation's answer under `result`, and what is about
//! the call itself under `meta`: `next`, the page after this one, for an operation answering
//! a page at a time. `meta` is where whatever else is told about a call goes.
//!
//!     { "result": { "operations": [...] }, "meta": { "next": "record.list" } }
const std = @import("std");
const sdk = @import("../../sdk.zig");

pub const Error = error{OutOfMemory};

/// A compiled operation's answer: `next`, when it answers a page at a time, lifted into
/// `meta`.
pub fn typed(arena: std.mem.Allocator, comptime Operation: type, out: Operation.Out) Error![]u8 {
    const paged = comptime sdk.operation.lists.paged(Operation);
    var written: std.Io.Writer.Allocating = .init(arena);
    var stringify: std.json.Stringify = .{
        .writer = &written.writer,
    };

    comptime std.debug.assert(@typeInfo(Operation.Out) == .@"struct");

    stringify.beginObject() catch return error.OutOfMemory;
    stringify.objectField("result") catch return error.OutOfMemory;
    stringify.beginObject() catch return error.OutOfMemory;

    inline for (comptime std.meta.fieldNames(Operation.Out)) |name| {
        if (comptime !paged or !std.mem.eql(u8, name, "next")) {
            stringify.objectField(name) catch return error.OutOfMemory;
            stringify.write(@field(out, name)) catch return error.OutOfMemory;
        }
    }

    stringify.endObject() catch return error.OutOfMemory;
    stringify.objectField("meta") catch return error.OutOfMemory;
    stringify.beginObject() catch return error.OutOfMemory;

    if (comptime paged) {
        stringify.objectField("next") catch return error.OutOfMemory;
        stringify.write(out.next) catch return error.OutOfMemory;
    }

    stringify.endObject() catch return error.OutOfMemory;
    stringify.endObject() catch return error.OutOfMemory;

    return written.written();
}

/// An installed operation's answer, as the JSON its plugin wrote: a `next` text at its top
/// lifted into `meta`.
pub fn text(arena: std.mem.Allocator, output: []const u8) Error![]u8 {
    std.debug.assert(output.len > 0);

    var value = std.json.parseFromSliceLeaky(std.json.Value, arena, output, .{}) catch {
        return wrapped(arena, output, null);
    };

    if (value != .object) {
        return wrapped(arena, output, null);
    }

    const next = value.object.get("next") orelse return wrapped(arena, output, null);

    if (next != .string) {
        return wrapped(arena, output, null);
    }

    _ = value.object.orderedRemove("next");

    const rest = std.json.Stringify.valueAlloc(arena, value, .{}) catch return error.OutOfMemory;

    return wrapped(arena, rest, next.string);
}

fn wrapped(arena: std.mem.Allocator, result: []const u8, next: ?[]const u8) Error![]u8 {
    std.debug.assert(result.len > 0);

    const meta = if (next) |position|
        std.json.Stringify.valueAlloc(arena, .{
            .next = position,
        }, .{}) catch return error.OutOfMemory
    else
        "{}";

    return std.fmt.allocPrint(arena, "{{\"result\":{s},\"meta\":{s}}}", .{
        result,
        meta,
    }) catch error.OutOfMemory;
}

test "an answer goes under result, a page's next under meta" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "{\"result\":{\"items\":[1]},\"meta\":{\"next\":\"b\"}}",
        try text(arena, "{\"items\":[1],\"next\":\"b\"}"),
    );
    try std.testing.expectEqualStrings(
        "{\"result\":{\"id\":\"a\"},\"meta\":{}}",
        try text(arena, "{\"id\":\"a\"}"),
    );

    const Paged = struct {
        pub const name = "test.paged";
        pub const In = struct {
            after: []const u8 = "",
        };
        pub const Out = struct {
            items: []const u32,
            next: []const u8 = "",
        };
    };

    try std.testing.expectEqualStrings(
        "{\"result\":{\"items\":[1,2]},\"meta\":{\"next\":\"2\"}}",
        try typed(arena, Paged, .{
            .items = &.{ 1, 2 },
            .next = "2",
        }),
    );
}
