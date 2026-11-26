//! `publr.json`: JSON as Publr's own wire reads and writes it. The same text and values as
//! `std.json` (unknown fields skipped, defaults filled), at a cost close to the bytes: an
//! installed plugin's budget counts every instruction, and `std.json`'s scanner spends
//! hundreds on each byte there.
const std = @import("std");
const wire_json = @import("../../sdk/plugin/wire_json.zig");

/// `text` read as a `Shape`, as `std.json.parseFromSliceLeaky` reads it with unknown fields
/// ignored. Text without escapes is not copied: `text` must live as long as the value.
pub fn parse(
    comptime Shape: type,
    arena: std.mem.Allocator,
    text: []const u8,
) error{ Invalid, OutOfMemory }!Shape {
    std.debug.assert(text.len <= std.math.maxInt(u32));

    return wire_json.parse(Shape, arena, text, .{});
}

/// `value` written as `std.json.Stringify.valueAlloc(arena, value, .{})` writes it.
pub fn stringify(arena: std.mem.Allocator, value: anytype) error{OutOfMemory}![]u8 {
    const text = try wire_json.stringify(arena, value);

    std.debug.assert(text.len > 0);

    return text;
}

test "publr.json reads and writes as std.json does" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Line = struct {
        title: []const u8,
        price: @import("../money.zig").Money = .{},
    };
    const line = try parse(Line, arena, "{\"title\":\"Tea\",\"price\":{\"PLN\":1200},\"x\":1}");

    try std.testing.expectEqualStrings("Tea", line.title);
    try std.testing.expectEqual(@as(i64, 1200), line.price.get("PLN").?);
    try std.testing.expectEqualStrings(
        "{\"title\":\"Tea\",\"price\":{\"PLN\":1200}}",
        try stringify(arena, line),
    );
}
