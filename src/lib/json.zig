//! Bound JSON nesting before typed parsing or later recursive rendering can consume the stack.
const std = @import("std");

pub const depth_max: u32 = 64;
pub const Error = std.json.ParseError(std.json.Scanner) || error{NestingTooDeep};

/// Returned values belong to the caller's arena, just as with parseFromSliceLeaky.
pub fn parse(
    comptime Shape: type,
    arena: std.mem.Allocator,
    text: []const u8,
    options: std.json.ParseOptions,
) Error!Shape {
    var scanner = std.json.Scanner.initCompleteInput(arena, text);
    defer scanner.deinit();
    var depth: u32 = 0;

    while (true) {
        switch (try scanner.next()) {
            .object_begin, .array_begin => {
                if (depth == depth_max) return error.NestingTooDeep;
                depth += 1;
            },
            .object_end, .array_end => {
                std.debug.assert(depth > 0);
                depth -= 1;
            },
            .end_of_document => break,
            else => {},
        }
    }

    std.debug.assert(depth == 0);
    return std.json.parseFromSliceLeaky(Shape, arena, text, options);
}

test "JSON nesting is bounded before parsing recursive structures" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const deep = "[" ** (depth_max + 1) ++ "0" ++ "]" ** (depth_max + 1);
    try std.testing.expectError(error.NestingTooDeep, parse(std.json.Value, arena, deep, .{}));
    const boundary = "[" ** depth_max ++ "0" ++ "]" ** depth_max;
    _ = try parse(std.json.Value, arena, boundary, .{});
    const text = try parse([]const u8, arena, "\"[[[{\\\"quoted\\\": true}]]]\"", .{});
    try std.testing.expectEqualStrings("[[[{\"quoted\": true}]]]", text);
}
