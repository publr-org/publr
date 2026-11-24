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
/// Nested installed calls' working memory: the deepest path of calls at once. A call past it
/// runs again in its caller's memory.
pub const call_bytes: u32 = 4 << 20;

pub const Scratch = struct {
    fixed: std.heap.FixedBufferAllocator,
    /// The most it held before something was given back, since `peak_reset`.
    peak: u32 = 0,

    pub const Mark = struct {
        index: u32,
    };

    pub fn allocator(scratch: *Scratch) std.mem.Allocator {
        std.debug.assert(scratch.fixed.buffer.len > 0);

        return scratch.fixed.allocator();
    }

    /// Whether `candidate` is this scratch: a caller working in it already (its loop set
    /// `ctx.arena` to it) keeps nothing past a nested rewind.
    pub fn holds(scratch: *Scratch, candidate: std.mem.Allocator) bool {
        std.debug.assert(scratch.fixed.buffer.len > 0);

        const mine = scratch.allocator();

        return candidate.ptr == mine.ptr and candidate.vtable == mine.vtable;
    }

    /// The most the scratch has held since `peak_reset`, in bytes.
    pub fn peak_bytes(scratch: *const Scratch) u32 {
        std.debug.assert(scratch.fixed.end_index <= scratch.fixed.buffer.len);

        return @max(scratch.peak, @as(u32, @intCast(scratch.fixed.end_index)));
    }

    /// What it holds now is the most it has held: a new measure begins.
    pub fn peak_reset(scratch: *Scratch) void {
        std.debug.assert(scratch.fixed.end_index <= scratch.fixed.buffer.len);

        scratch.peak = @intCast(scratch.fixed.end_index);
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

        scratch.peak = scratch.peak_bytes();

        // What is given back reads as undefined in a safe build: a read past the rewind
        // shows there, never only as a fast build's crash.
        if (std.debug.runtime_safety) {
            @memset(scratch.fixed.buffer[at.index..scratch.fixed.end_index], undefined);
        }

        scratch.fixed.end_index = at.index;

        std.debug.assert(scratch.fixed.end_index == at.index);
    }

    /// Whether `bytes` lie in the scratch at or past `at`: given back with a rewind to it.
    pub fn lies_past(scratch: *const Scratch, at: Mark, bytes: []const u8) bool {
        const base = @intFromPtr(scratch.fixed.buffer.ptr);
        const from = @intFromPtr(bytes.ptr);

        std.debug.assert(at.index <= scratch.fixed.buffer.len);

        if (bytes.len == 0) {
            return false;
        }

        return from >= base + at.index and from + bytes.len <= base + scratch.fixed.buffer.len;
    }

    /// `kept`, taken anywhere in the scratch at or past `at`, moved down to `at`, and
    /// everything else past `at` given back: nothing is laid a second time on the way.
    /// Null when `kept` is not in the scratch past `at`: nothing was moved or given back.
    pub fn keep_from(scratch: *Scratch, at: Mark, kept: []const u8) ?[]u8 {
        const buffer = scratch.fixed.buffer;
        const base = @intFromPtr(buffer.ptr);
        const from = @intFromPtr(kept.ptr);

        std.debug.assert(at.index <= scratch.fixed.end_index);

        if (from < base + at.index or from + kept.len > base + scratch.fixed.end_index) {
            return null;
        }

        const low = buffer[at.index..][0..kept.len];

        // Laid at `at`, at or below `kept`: a forward copy never overwrites what it reads next.
        std.mem.copyForwards(u8, low, kept);

        const end = at.index + kept.len;

        scratch.peak = scratch.peak_bytes();

        if (std.debug.runtime_safety) {
            @memset(buffer[end..scratch.fixed.end_index], undefined);
        }

        scratch.fixed.end_index = end;

        std.debug.assert(scratch.fixed.end_index >= at.index);

        return low;
    }

    /// `kept`, taken last, moved down to `at`, and everything past it given back: what an
    /// item keeps when it ends in the scratch its caller works in.
    pub fn keep_at(scratch: *Scratch, at: Mark, kept: []const u8) []u8 {
        const buffer = scratch.fixed.buffer;
        const start: u64 = @intFromPtr(kept.ptr) -| @intFromPtr(buffer.ptr);

        std.debug.assert(at.index <= start);
        std.debug.assert(start + kept.len == scratch.fixed.end_index);

        const low = buffer[at.index..][0..kept.len];

        // Laid at `at`, at or below `kept`: a forward copy never overwrites what it reads next.
        std.mem.copyForwards(u8, low, kept);
        scratch.rewind(.{
            .index = @intCast(at.index + kept.len),
        });

        return low;
    }
};

/// What `arena` holds now when it is a fixed buffer (a command's request arena), else null.
pub fn used_of(arena: std.mem.Allocator) ?u64 {
    var none: std.heap.FixedBufferAllocator = .init(&.{});

    if (arena.vtable != none.allocator().vtable) {
        return null;
    }

    const fixed: *const std.heap.FixedBufferAllocator = @ptrCast(@alignCast(arena.ptr));

    std.debug.assert(fixed.end_index <= fixed.buffer.len);

    return fixed.end_index;
}

test "a scratch remembers the most it held, and a fixed buffer says what it holds" {
    var buffer: [64]u8 = undefined;
    var scratch: Scratch = .{
        .fixed = .init(&buffer),
    };
    const at = scratch.mark();

    _ = try scratch.allocator().alloc(u8, 40);
    scratch.rewind(at);
    _ = try scratch.allocator().alloc(u8, 8);

    try std.testing.expectEqual(@as(u32, 40), scratch.peak_bytes());
    try std.testing.expectEqual(@as(?u64, 8), used_of(scratch.allocator()));
    try std.testing.expectEqual(@as(?u64, null), used_of(std.testing.allocator));

    scratch.peak_reset();
    try std.testing.expectEqual(@as(u32, 8), scratch.peak_bytes());
}

test "bytes taken anywhere past the mark move down to it without a second copy" {
    var buffer: [64]u8 = undefined;
    var scratch: Scratch = .{
        .fixed = .init(&buffer),
    };
    const begun = scratch.mark();

    @memset(try scratch.allocator().alloc(u8, 10), 1);

    const kept = try scratch.allocator().alloc(u8, 20);

    for (kept, 0..) |*byte, index| {
        byte.* = @truncate(index + 100);
    }

    @memset(try scratch.allocator().alloc(u8, 30), 2);

    const low = scratch.keep_from(begun, kept).?;

    try std.testing.expectEqual(@as(usize, 20), scratch.fixed.end_index);
    try std.testing.expectEqual(@as(u8, 100), low[0]);
    try std.testing.expectEqual(@as(u8, 119), low[19]);

    // Bytes that are not in the scratch are none of its to move.
    const outside = [_]u8{ 1, 2, 3 };

    try std.testing.expectEqual(@as(?[]u8, null), scratch.keep_from(begun, &outside));
    try std.testing.expectEqual(@as(usize, 20), scratch.fixed.end_index);
}

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

test "what is given back reads as undefined in a safe build" {
    var buffer: [64]u8 = undefined;
    var scratch: Scratch = .{
        .fixed = .init(&buffer),
    };
    const begun = scratch.mark();
    const working = try scratch.allocator().alloc(u8, 16);

    @memset(working, 7);
    scratch.rewind(begun);

    if (std.debug.runtime_safety) {
        try std.testing.expectEqual(@as(u8, 0xaa), buffer[15]);
    }

    try std.testing.expectEqual(@as(usize, 0), scratch.fixed.end_index);
}

test "kept bytes move down to the mark and the rest is given back" {
    var buffer: [64]u8 = undefined;
    var scratch: Scratch = .{
        .fixed = .init(&buffer),
    };
    const begun = scratch.mark();

    @memset(try scratch.allocator().alloc(u8, 20), 1);

    const high = try scratch.allocator().alloc(u8, 30);

    for (high, 0..) |*byte, index| {
        byte.* = @truncate(index);
    }

    const low = scratch.keep_at(begun, high);

    try std.testing.expectEqual(@as(usize, 30), scratch.fixed.end_index);
    try std.testing.expectEqual(@as(u8, 29), low[29]);
    try std.testing.expectEqual(@as(u8, 0), low[0]);
    try std.testing.expectEqual(@intFromPtr(&buffer), @intFromPtr(low.ptr));
}

test "an item larger than the scratch is refused" {
    var buffer: [512]u8 = undefined;
    var scratch: Scratch = .{
        .fixed = .init(&buffer),
    };

    try std.testing.expectError(error.OutOfMemory, scratch.allocator().alloc(u8, 513));
}
