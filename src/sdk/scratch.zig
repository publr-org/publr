//! Working memory for one item of a loop over many. The request's arena only grows until
//! the request ends, so a loop that keeps each item's working data there takes the sum of
//! every item. A scratch is a buffer set aside once per process (`ctx.scratch`; from the
//! arena where the process set none aside) and given back after each item: the loop takes
//! its largest item's memory, and keeps only its results in the arena. Marks nest, so a
//! loop inside an item of another (an operation called from it) gives back only its own.
const std = @import("std");

/// One request's scratch: the most an item's working data may take, every nested loop's
/// items included.
pub const bytes_default: u32 = 1 << 20;

pub const Scratch = struct {
    fixed: std.heap.FixedBufferAllocator,

    pub const Mark = struct {
        index: u32,
    };

    pub fn allocator(scratch: *Scratch) std.mem.Allocator {
        std.debug.assert(scratch.fixed.buffer.len > 0);

        return scratch.fixed.allocator();
    }

    /// Where an item begins: `rewind` to it once the item is done.
    pub fn mark(scratch: *const Scratch) Mark {
        std.debug.assert(scratch.fixed.end_index <= scratch.fixed.buffer.len);

        return .{
            .index = @intCast(scratch.fixed.end_index),
        };
    }

    /// Everything taken since `at` given back: nothing taken since is read after this.
    pub fn rewind(scratch: *Scratch, at: Mark) void {
        std.debug.assert(at.index <= scratch.fixed.end_index);

        scratch.fixed.end_index = at.index;

        std.debug.assert(scratch.fixed.end_index == at.index);
    }
};

test "a scratch holds one item at a time, however many there are" {
    var buffer: [1024]u8 = undefined;
    var scratch: Scratch = .{
        .fixed = .init(&buffer),
    };
    var item: u32 = 0;

    while (item < 100) : (item += 1) {
        const begun = scratch.mark();
        defer scratch.rewind(begun);

        const working = try scratch.allocator().alloc(u8, 1000);

        @memset(working, @truncate(item));
        try std.testing.expectEqual(@as(u8, @truncate(item)), working[999]);
    }

    try std.testing.expectEqual(@as(usize, 0), scratch.fixed.end_index);
}

test "a nested loop gives back only its own items" {
    var buffer: [1024]u8 = undefined;
    var scratch: Scratch = .{
        .fixed = .init(&buffer),
    };
    const outer = scratch.mark();
    const kept = try scratch.allocator().alloc(u8, 100);

    @memset(kept, 7);

    var item: u32 = 0;

    while (item < 10) : (item += 1) {
        const inner = scratch.mark();
        defer scratch.rewind(inner);

        @memset(try scratch.allocator().alloc(u8, 900), 1);
    }

    try std.testing.expectEqual(@as(u8, 7), kept[99]);

    scratch.rewind(outer);

    try std.testing.expectEqual(@as(usize, 0), scratch.fixed.end_index);
}

test "an item larger than the scratch is refused" {
    var buffer: [512]u8 = undefined;
    var scratch: Scratch = .{
        .fixed = .init(&buffer),
    };

    try std.testing.expectError(error.OutOfMemory, scratch.allocator().alloc(u8, 513));
}
