//! A plugin's general allocator, for what outlives one call's arena or is freed before it
//! ends. Small requests go to the allocator it is given; from `pages_from_bytes` a request
//! takes whole pages, exactly as many as it needs, and grows where it is when the pages
//! after it are free or memory ends there.

const std = @import("std");
const runs_module = @import("runs.zig");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const page_bytes = runs_module.page_bytes;

/// From this size a request takes whole pages.
pub const pages_from_bytes: u32 = 16 << 10;

/// The size std's allocator interface gives and takes.
const Bytes = usize;

pub fn Heap(comptime Memory: type) type {
    return struct {
        runs: *runs_module.Runs(Memory),
        small: Allocator,

        const Self = @This();

        pub fn allocator(heap: *const Self) Allocator {
            return .{
                .ptr = @constCast(heap),
                .vtable = &.{
                    .alloc = alloc,
                    .resize = resize,
                    .remap = remap,
                    .free = free,
                },
            };
        }

        fn alloc(ctx: *anyopaque, len: Bytes, alignment: Alignment, return_address: Bytes) ?[*]u8 {
            const heap: *const Self = @ptrCast(@alignCast(ctx));

            std.debug.assert(len > 0);

            if (!in_pages(len, alignment)) {
                return heap.small.rawAlloc(len, alignment, return_address);
            }

            const page = heap.runs.take(pages_for(len) orelse return null) orelse return null;

            return @ptrFromInt(@as(usize, @intCast(heap.runs.address(page))));
        }

        fn resize(
            ctx: *anyopaque,
            memory: []u8,
            alignment: Alignment,
            new_len: Bytes,
            return_address: Bytes,
        ) bool {
            const heap: *const Self = @ptrCast(@alignCast(ctx));
            const paged = in_pages(memory.len, alignment);

            std.debug.assert(memory.len > 0);

            // A request stays in pages or out of them: its size says which allocator frees it.
            if (paged != in_pages(new_len, alignment)) {
                return false;
            }

            if (!paged) {
                return heap.small.rawResize(memory, alignment, new_len, return_address);
            }

            const page = heap.runs.page_at(@intFromPtr(memory.ptr));
            const held = pages_for(memory.len).?;
            const needed = pages_for(new_len) orelse return false;

            if (needed < held) {
                heap.runs.give(page + needed, held - needed);

                return true;
            }

            return needed == held or heap.runs.extend(page + held, needed - held);
        }

        fn remap(
            ctx: *anyopaque,
            memory: []u8,
            alignment: Alignment,
            new_len: Bytes,
            return_address: Bytes,
        ) ?[*]u8 {
            const resized = resize(ctx, memory, alignment, new_len, return_address);

            return if (resized) memory.ptr else null;
        }

        fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, return_address: Bytes) void {
            const heap: *const Self = @ptrCast(@alignCast(ctx));

            std.debug.assert(memory.len > 0);

            if (!in_pages(memory.len, alignment)) {
                return heap.small.rawFree(memory, alignment, return_address);
            }

            heap.runs.give(heap.runs.page_at(@intFromPtr(memory.ptr)), pages_for(memory.len).?);
        }
    };
}

fn in_pages(len: Bytes, alignment: Alignment) bool {
    return len >= pages_from_bytes and alignment.toByteUnits() <= page_bytes;
}

/// The pages `len` bytes take; null past what a plugin's memory could ever hold.
fn pages_for(len: Bytes) ?u32 {
    std.debug.assert(len > 0);

    if (len > std.math.maxInt(u32) / 2) {
        return null;
    }

    return @intCast((len + (page_bytes - 1)) / page_bytes);
}

const TestMemory = runs_module.TestMemory;

test "small requests go to the small allocator, large ones take and give back whole pages" {
    var state: TestMemory.State = try .init(std.testing.allocator);
    defer state.deinit(std.testing.allocator);

    var runs: runs_module.Runs(TestMemory) = .{
        .memory = .{
            .state = &state,
        },
    };
    const heap: Heap(TestMemory) = .{
        .runs = &runs,
        .small = std.testing.allocator,
    };
    const memory = heap.allocator();

    const small = try memory.alloc(u8, pages_from_bytes - 1);
    defer memory.free(small);

    try std.testing.expectEqual(@as(u32, 1), state.pages);
    try std.testing.expect(!memory.resize(small, pages_from_bytes));

    const large = try memory.alloc(u8, pages_from_bytes);

    try std.testing.expectEqual(@as(u32, 2), state.pages);
    try std.testing.expect(!memory.resize(large, 100));

    memory.free(large);
    try std.testing.expectEqual(@as(u32, 1), runs.free_pages());

    const exact = try memory.alloc(u8, 3 * page_bytes);

    try std.testing.expectEqual(@as(u32, 4), state.pages);
    try std.testing.expectEqual(@as(u32, 0), runs.free_pages());
    memory.free(exact);
    try std.testing.expectEqual(@as(u32, 3), runs.free_pages());
}

test "a large request grows where it is, shrinks by pages, and moves when it cannot grow" {
    var state: TestMemory.State = try .init(std.testing.allocator);
    defer state.deinit(std.testing.allocator);

    var runs: runs_module.Runs(TestMemory) = .{
        .memory = .{
            .state = &state,
        },
    };
    const heap: Heap(TestMemory) = .{
        .runs = &runs,
        .small = std.testing.allocator,
    };
    const memory = heap.allocator();

    var buffer = try memory.alloc(u8, page_bytes);
    const start = buffer.ptr;

    @memset(buffer, 7);
    buffer = try memory.realloc(buffer, 3 * page_bytes);
    try std.testing.expectEqual(start, buffer.ptr);
    try std.testing.expectEqual(@as(u32, 4), state.pages);

    buffer = try memory.realloc(buffer, page_bytes + 1);
    try std.testing.expectEqual(start, buffer.ptr);
    try std.testing.expectEqual(@as(u32, 1), runs.free_pages());

    // Another request takes the page after it: growing then moves it, and its pages come back.
    const other = try memory.alloc(u8, page_bytes);

    buffer = try memory.realloc(buffer, 4 * page_bytes);
    try std.testing.expect(buffer.ptr != start);
    try std.testing.expectEqual(@as(u8, 7), buffer[page_bytes - 1]);
    try std.testing.expectEqual(@as(u32, 2), runs.free_pages());

    const all = TestMemory.pages_max * page_bytes;

    try std.testing.expectError(error.OutOfMemory, memory.alloc(u8, all));
    memory.free(other);
    memory.free(buffer);
    try std.testing.expectEqual(state.pages - 1, runs.free_pages());
}
