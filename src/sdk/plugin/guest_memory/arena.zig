//! One call's memory. Small requests fill blocks of whole pages, the newest from its start,
//! the last one made growing where it is. A request of a page or more takes pages of its own,
//! exactly as many as it needs: it grows and shrinks by pages and is given back when freed, so
//! a buffer that outgrows itself leaves nothing behind. Everything goes back to the free runs
//! when the call ends.

const std = @import("std");
const large_module = @import("large.zig");
const runs_module = @import("runs.zig");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const page_bytes = runs_module.page_bytes;

/// What an arena asks for after its first block, at least: fewer, larger blocks.
const block_pages_min: u32 = 4;

/// The size std's allocator interface gives and takes.
const Bytes = usize;

pub fn Arena(comptime Memory: type) type {
    return struct {
        runs: *runs_module.Runs(Memory),
        blocks: ?*Block = null,
        /// The small request made last: it alone grows where it is.
        last: ?[*]u8 = null,
        last_len: u32 = 0,
        /// Requests of a page or more, which take pages of their own.
        large: large_module.Requests(Memory) = .{},

        const Self = @This();

        /// A block of pages: this sits at its start.
        const Block = struct {
            next: ?*Block,
            pages: u32,
            /// Bytes used, this header included.
            used: u32,
        };

        pub fn allocator(arena: *Self) Allocator {
            return .{
                .ptr = arena,
                .vtable = &.{
                    .alloc = alloc,
                    .resize = resize,
                    .remap = remap,
                    .free = free,
                },
            };
        }

        /// What the arena holds reads as undefined in a safe build, so a read past its end shows
        /// there, never only as a fast build's crash. The requests with pages of their own are
        /// given back first, while the blocks still note them; `deinit` gives back the rest.
        pub fn poison(arena: *Self) void {
            if (!std.debug.runtime_safety) {
                return;
            }

            var node = arena.large.held;

            while (node) |held| : (node = held.next) {
                const whole: [*]u8 = @ptrFromInt(@as(usize, @intCast(arena.runs.address(
                    held.page,
                ))));

                std.debug.assert(held.pages > 0);

                @memset(whole[0 .. @as(usize, held.pages) * page_bytes], undefined);
            }

            arena.large.give_all(arena.runs);

            var block = arena.blocks;

            while (block) |held| : (block = held.next) {
                const whole: [*]u8 = @ptrCast(held);

                std.debug.assert(held.used <= held.pages * page_bytes);

                @memset(whole[@sizeOf(Block)..held.used], undefined);
            }
        }

        /// Every page the arena holds given back.
        pub fn deinit(arena: *Self) void {
            arena.large.give_all(arena.runs);

            var block = arena.blocks;

            while (block) |held| {
                const next = held.next;

                std.debug.assert(held.used <= held.pages * page_bytes);

                arena.runs.give(arena.runs.page_at(@intFromPtr(held)), held.pages);
                block = next;
            }

            arena.* = .{
                .runs = arena.runs,
            };
        }

        fn alloc(ctx: *anyopaque, len: Bytes, alignment: Alignment, _: Bytes) ?[*]u8 {
            const arena: *Self = @ptrCast(@alignCast(ctx));

            std.debug.assert(len > 0);

            if (alignment.toByteUnits() > page_bytes or len > std.math.maxInt(u32) / 2) {
                return null;
            }

            if (len >= page_bytes) {
                return arena.alloc_large(@intCast(len));
            }

            return arena.alloc_small(@intCast(len), alignment);
        }

        fn alloc_large(arena: *Self, len: u32) ?[*]u8 {
            std.debug.assert(len >= page_bytes);

            const Node = large_module.Node;
            const node = arena.large.spare_node() orelse node: {
                const made = arena.alloc_small(@sizeOf(Node), .of(Node)) orelse return null;

                break :node @as(*Node, @ptrCast(@alignCast(made)));
            };

            return arena.large.take(arena.runs, node, pages_for(len));
        }

        fn alloc_small(arena: *Self, len: u32, alignment: Alignment) ?[*]u8 {
            std.debug.assert(len < page_bytes);

            if (arena.blocks) |block| {
                if (place(block, len, alignment)) |start| {
                    return arena.took(start, len);
                }
            }

            const alignment_bytes: u32 = @intCast(alignment.toByteUnits());
            const needed = pages_for(@sizeOf(Block) + alignment_bytes + len);
            const pages = if (arena.blocks == null) needed else @max(needed, block_pages_min);
            const page = arena.runs.take(pages) orelse return null;
            const block: *Block = @ptrFromInt(@as(usize, @intCast(arena.runs.address(page))));

            block.* = .{
                .next = arena.blocks,
                .pages = pages,
                .used = @sizeOf(Block),
            };
            arena.blocks = block;

            return arena.took(place(block, len, alignment).?, len);
        }

        fn took(arena: *Self, start: [*]u8, len: u32) [*]u8 {
            arena.last = start;
            arena.last_len = len;

            return start;
        }

        /// Room for `len` bytes in `block`, taken; null when it does not fit.
        fn place(block: *Block, len: u32, alignment: Alignment) ?[*]u8 {
            const base = @intFromPtr(block);
            const start = alignment.forward(base + block.used);
            const end = start + len;

            std.debug.assert(block.used >= @sizeOf(Block));
            std.debug.assert(block.used <= block.pages * page_bytes);

            if (end > base + @as(u64, block.pages) * page_bytes) {
                return null;
            }

            block.used = @intCast(end - base);

            return @ptrFromInt(start);
        }

        fn is_last(arena: *const Self, memory: []u8) bool {
            return memory.len > 0 and memory.ptr == arena.last and memory.len == arena.last_len;
        }

        fn resize(ctx: *anyopaque, memory: []u8, _: Alignment, new_len: Bytes, _: Bytes) bool {
            const arena: *Self = @ptrCast(@alignCast(ctx));
            const large = memory.len >= page_bytes;

            std.debug.assert(memory.len > 0);

            // A request stays large or small: its size says how it is freed.
            if (large != (new_len >= page_bytes) or new_len > std.math.maxInt(u32) / 2) {
                return false;
            }

            if (large) {
                return arena.large.resize(arena.runs, memory.ptr, pages_for(@intCast(new_len)));
            }

            if (arena.is_last(memory)) {
                return arena.resize_last(@intCast(new_len));
            }

            // Anything else only ever shrinks where it is.
            return new_len <= memory.len;
        }

        /// The request made last grown or shrunk where it is, its block taking the pages
        /// after it when it must.
        fn resize_last(arena: *Self, new_len: u32) bool {
            const block = arena.blocks.?;
            const len = arena.last_len;

            std.debug.assert(new_len < page_bytes);
            std.debug.assert(block.used >= @sizeOf(Block) + len);

            if (new_len <= len) {
                block.used -= len - new_len;
                arena.last_len = new_len;

                if (new_len == 0) {
                    arena.last = null;
                }

                return true;
            }

            const more = new_len - len;
            const room = block.pages * page_bytes - block.used;

            if (more > room) {
                const pages = pages_for(more - room);
                const end = arena.runs.page_at(@intFromPtr(block)) + block.pages;

                if (!arena.runs.extend(end, pages)) {
                    return false;
                }

                block.pages += pages;
            }

            block.used += more;
            arena.last_len = new_len;

            return true;
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

        fn free(ctx: *anyopaque, memory: []u8, _: Alignment, _: Bytes) void {
            const arena: *Self = @ptrCast(@alignCast(ctx));

            std.debug.assert(memory.len > 0);

            if (memory.len >= page_bytes) {
                return arena.large.free(arena.runs, memory.ptr);
            }

            if (arena.is_last(memory)) {
                arena.blocks.?.used -= arena.last_len;
                arena.last = null;
                arena.last_len = 0;
            }
        }
    };
}

fn pages_for(len: u32) u32 {
    std.debug.assert(len > 0);

    return (len + (page_bytes - 1)) / page_bytes;
}

const TestMemory = runs_module.TestMemory;

const Fixture = struct {
    state: TestMemory.State,
    runs: runs_module.Runs(TestMemory),

    fn init(fixture: *Fixture) !void {
        fixture.state = try .init(std.testing.allocator);
        fixture.runs = .{
            .memory = .{
                .state = &fixture.state,
            },
        };
    }

    fn deinit(fixture: *Fixture) void {
        fixture.state.deinit(std.testing.allocator);
    }

    fn held(fixture: *const Fixture) u32 {
        return fixture.state.pages - 1 - fixture.runs.free_pages();
    }
};

test "small requests fill one block; the end of the call gives every page back" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena: Arena(TestMemory) = .{
        .runs = &fixture.runs,
    };
    const memory = arena.allocator();

    const first = try memory.alloc(u8, 100);
    const second = try memory.alloc(u64, 10);

    @memset(first, 1);
    @memset(second, 2);
    try std.testing.expectEqual(@as(u32, 1), fixture.held());
    try std.testing.expect(@intFromPtr(second.ptr) > @intFromPtr(first.ptr));

    // The first block is full: the next one is larger, so fewer are made.
    _ = try memory.alloc(u8, page_bytes - 1);
    try std.testing.expectEqual(@as(u32, 1 + block_pages_min), fixture.held());
    try std.testing.expectEqual(@as(u8, 1), first[99]);

    arena.deinit();
    try std.testing.expectEqual(@as(u32, 0), fixture.held());
    try std.testing.expectEqual(@as(?*Arena(TestMemory).Block, null), arena.blocks);
}

test "a growing buffer takes pages of its own and leaves nothing behind" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena: Arena(TestMemory) = .{
        .runs = &fixture.runs,
    };
    defer arena.deinit();

    const memory = arena.allocator();
    var list: std.ArrayList(u8) = .empty;

    for (0..6 * page_bytes) |index| {
        try list.append(memory, @truncate(index));
    }

    for (list.items, 0..) |byte, index| {
        try std.testing.expectEqual(@as(u8, @truncate(index)), byte);
    }

    // The buffer's own pages, exactly, beside the block its small beginnings filled.
    const buffer_pages = pages_for(@intCast(list.capacity));
    const block_pages = fixture.held() - buffer_pages;

    try std.testing.expect(block_pages >= 1);
    try std.testing.expect(block_pages <= 2);

    list.shrinkAndFree(memory, 2 * page_bytes);
    try std.testing.expectEqual(block_pages + 2, fixture.held());

    list.deinit(memory);
    try std.testing.expectEqual(block_pages, fixture.held());

    // The note of a freed large request is used for the next: no new block for it.
    const again = try memory.alloc(u8, page_bytes);

    try std.testing.expectEqual(block_pages + 1, fixture.held());
    memory.free(again);
    try std.testing.expectEqual(block_pages, fixture.held());
}

test "only the last small request grows where it is; a full memory is an error" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena: Arena(TestMemory) = .{
        .runs = &fixture.runs,
    };
    defer arena.deinit();

    const memory = arena.allocator();
    const first = try memory.alloc(u8, 64);
    var last = try memory.alloc(u8, 64);

    try std.testing.expect(!memory.resize(first, 128));
    try std.testing.expect(memory.resize(first, 32));
    try std.testing.expect(memory.resize(last, 4096));
    last = last.ptr[0..4096];

    // Small stays small and large stays large: a move is the caller's to make.
    try std.testing.expect(!memory.resize(last, page_bytes));

    const large = try memory.alloc(u8, 2 * page_bytes);

    try std.testing.expect(!memory.resize(large, 100));
    try std.testing.expect(memory.resize(large, page_bytes));
    try std.testing.expectEqual(@as(u32, 2), fixture.held());

    const all = TestMemory.pages_max * page_bytes;

    try std.testing.expectError(error.OutOfMemory, memory.alloc(u8, all));
    try std.testing.expectEqual(@as(u32, 2), fixture.held());
}
