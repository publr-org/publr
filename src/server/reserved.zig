//! Large buffers a server holds for its whole life, reserved but not written. The generic
//! `alloc` fills new memory with `undefined`, which safe builds (releases) write out, so every
//! page would count against the process from its first second whatever it later needs. The
//! raw path commits pages as they are touched; `release` gives them back without writing.

const std = @import("std");

pub fn reserve(
    gpa: std.mem.Allocator,
    comptime alignment: std.mem.Alignment,
    len: u32,
) error{OutOfMemory}![]align(alignment.toByteUnits()) u8 {
    std.debug.assert(len > 0);
    std.debug.assert(len % alignment.toByteUnits() == 0);

    const ptr = gpa.rawAlloc(len, alignment, @returnAddress()) orelse return error.OutOfMemory;

    return @alignCast(ptr[0..len]);
}

pub fn release(
    gpa: std.mem.Allocator,
    comptime alignment: std.mem.Alignment,
    buffer: []align(alignment.toByteUnits()) u8,
) void {
    std.debug.assert(buffer.len > 0);
    std.debug.assert(buffer.len % alignment.toByteUnits() == 0);

    gpa.rawFree(buffer, alignment, @returnAddress());
}

test "a reserved buffer is given back" {
    const buffer = try reserve(std.testing.allocator, .@"8", 1 << 16);
    defer release(std.testing.allocator, .@"8", buffer);

    buffer[0] = 1;
    buffer[buffer.len - 1] = 2;
    try std.testing.expectEqual(@as(usize, 1 << 16), buffer.len);
}
