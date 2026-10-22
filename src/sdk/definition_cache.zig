//! Definitions read once per request. A page that reads many records looks their type up
//! many times (each read checks it, lists it, resolves it); decoding the type each time
//! makes a request cost its records times its type's size. Here each type is decoded once
//! for the request and handed back after. Entries live in the request's arena, so the
//! cache answers only while that request runs (`begin` .. `end`) and only to contexts on
//! its arena or its scratch; every write forgets everything, so a type changed is read again.
const std = @import("std");
const Scratch = @import("scratch.zig").Scratch;

const entries_max: u32 = 64;
const key_len_max: u32 = 160;

pub const DefinitionCache = struct {
    entries: [entries_max]Entry = undefined,
    len: u32 = 0,
    /// The arena of the request running; null between requests.
    arena: ?std.mem.Allocator = null,

    const Entry = struct {
        key: [key_len_max]u8,
        key_len: u32,
        row: *const anyopaque,
    };

    /// A request starts on `arena`: what an earlier one kept is gone.
    pub fn begin(cache: *DefinitionCache, arena: std.mem.Allocator) void {
        cache.len = 0;
        cache.arena = arena;

        std.debug.assert(cache.arena != null);
    }

    /// The request ended: nothing answers until the next begins.
    pub fn end(cache: *DefinitionCache) void {
        cache.len = 0;
        cache.arena = null;

        std.debug.assert(cache.len == 0);
    }

    /// A write ran: everything is read again.
    pub fn forget(cache: *DefinitionCache) void {
        cache.len = 0;

        std.debug.assert(cache.len == 0);
    }

    /// The arena the cache answers a context on `arena` on: the request's, for a context on
    /// it or on the request's `scratch` (a page read there, whose definitions the request's
    /// arena keeps); null for any other, or between requests.
    pub fn arena_for(
        cache: *const DefinitionCache,
        arena: std.mem.Allocator,
        scratch: ?*Scratch,
    ) ?std.mem.Allocator {
        std.debug.assert(cache.len <= entries_max);
        std.debug.assert(cache.arena != null or cache.len == 0);

        const request = cache.arena orelse return null;

        if (arena.ptr == request.ptr) {
            return request;
        }

        const set_aside = scratch orelse return null;
        const on_scratch = arena.ptr == @as(*anyopaque, @ptrCast(&set_aside.fixed));

        return if (on_scratch) request else null;
    }

    /// What was kept for `key`; null when nothing was or no request runs. Callers read on
    /// the arena `arena_for` answered.
    pub fn get(cache: *const DefinitionCache, key: []const u8) ?*const anyopaque {
        std.debug.assert(cache.len <= entries_max);

        if (cache.arena == null or key.len > key_len_max) {
            return null;
        }

        for (cache.entries[0..cache.len]) |*entry| {
            if (std.mem.eql(u8, entry.key[0..entry.key_len], key)) {
                return entry.row;
            }
        }

        return null;
    }

    /// `row` (in the request's arena) kept for `key` while there is room; otherwise nothing
    /// is kept and the next read decodes again.
    pub fn put(cache: *DefinitionCache, key: []const u8, row: *const anyopaque) void {
        std.debug.assert(cache.len <= entries_max);

        if (cache.arena == null or key.len > key_len_max or cache.len == entries_max) {
            return;
        }

        const entry = &cache.entries[cache.len];

        @memcpy(entry.key[0..key.len], key);
        entry.key_len = @intCast(key.len);
        entry.row = row;
        cache.len += 1;
    }
};

test "a definition kept for the request answers while it runs, until a write" {
    var buffer: [256]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    var cache: DefinitionCache = .{};
    const row: u32 = 7;

    cache.put("record:post", &row);
    try std.testing.expectEqual(null, cache.get("record:post"));

    cache.begin(fixed.allocator());
    cache.put("record:post", &row);
    const kept = cache.get("record:post");
    try std.testing.expect(kept == @as(*const anyopaque, &row));

    cache.forget();
    try std.testing.expectEqual(null, cache.get("record:post"));

    cache.put("record:post", &row);
    cache.end();
    try std.testing.expectEqual(null, cache.get("record:post"));
}

test "a context on the request's scratch is answered on the request's arena" {
    var buffer: [256]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    var scratch_buffer: [128]u8 = undefined;
    var scratch: Scratch = .{
        .fixed = .init(&scratch_buffer),
    };
    var other_buffer: [128]u8 = undefined;
    var other: Scratch = .{
        .fixed = .init(&other_buffer),
    };
    var cache: DefinitionCache = .{};

    try std.testing.expectEqual(null, cache.arena_for(scratch.allocator(), &scratch));

    cache.begin(fixed.allocator());

    const answered = cache.arena_for(scratch.allocator(), &scratch).?;

    try std.testing.expect(answered.ptr == fixed.allocator().ptr);
    try std.testing.expectEqual(null, cache.arena_for(other.allocator(), &scratch));
    try std.testing.expectEqual(null, cache.arena_for(scratch.allocator(), null));

    cache.end();
    try std.testing.expectEqual(null, cache.arena_for(fixed.allocator(), &scratch));
}
