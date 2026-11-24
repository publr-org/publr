//! Compiled-in plugins' working memory. An installed plugin works in memory of its own: each
//! call into it has an arena, given back as the call returns, and `ctx.scope()` gives a
//! step's memory back before the call ends. A compiled-in plugin gets the same, from the
//! same allocator (`plugin/guest_memory`): one piece of memory the process sets aside for
//! all of them, as large as one installed plugin may hold, taken in whole pages by each
//! piece of work (an operation, a hook, a modifier, a job, a scope) and given back as it
//! ends. What the work answers is copied to its caller's memory first (`moved.zig`), so the
//! request's arena holds what lasts the request and never a plugin's working data.
const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const arena_module = @import("plugin/guest_memory/arena.zig");
const runs_module = @import("plugin/guest_memory/runs.zig");
const limits_default = @import("../model/sandboxed_plugin.zig").limits_default;

pub const page_bytes: u32 = runs_module.page_bytes;
/// What every compiled-in plugin's work may hold at once: one installed plugin's ceiling,
/// in the layout a compiled-in plugin has. An installed plugin's addresses and lengths are
/// four bytes each; here they are as wide as the machine's, so the same structs take up to
/// twice the room.
pub const bytes: u32 = (limits_default.memory_mib << 20) * (@sizeOf(usize) / 4);
pub const alignment: std.mem.Alignment = .fromByteUnits(page_bytes);

pub const Buffer = []align(page_bytes) u8;

/// The pages as the allocator sees them: page 1 is the buffer's first.
const Region = struct {
    held: *Held,

    pub fn base_address(region: Region) u64 {
        return @intFromPtr(region.held.buffer.ptr) - page_bytes;
    }

    pub fn pages(region: Region) u32 {
        return region.held.pages + 1;
    }

    pub fn grow(region: Region, more: u32) bool {
        const held = region.held;
        const pages_max: u32 = @intCast(held.buffer.len / page_bytes);

        std.debug.assert(held.pages <= pages_max);

        if (more > pages_max - held.pages) {
            return false;
        }

        held.pages += more;

        return true;
    }
};

const Held = struct {
    buffer: Buffer,
    /// Pages taken from the buffer's start since `fresh`: the most held at once.
    pages: u32 = 0,
};

pub const Arena = arena_module.Arena(Region);

pub const Memory = struct {
    held: Held,
    runs: runs_module.Runs(Region),
    /// Pieces of work holding memory now.
    open: u32 = 0,
    /// Pieces of work begun since `fresh`.
    begun: u32 = 0,
    /// The largest a plugin's SDK collection held since `fresh` (`publr.List`, `publr.IdMap`):
    /// what the half-limit line and an out-of-memory failure name.
    largest_name: []const u8 = "",
    largest_bytes: u64 = 0,

    /// Over `buffer`, whole pages. The memory points at itself: it stays where it is made.
    pub fn init(memory: *Memory, buffer: Buffer) void {
        std.debug.assert(buffer.len >= page_bytes);
        std.debug.assert(buffer.len % page_bytes == 0);

        memory.* = .{
            .held = .{
                .buffer = buffer,
            },
            .runs = .{
                .memory = .{
                    .held = &memory.held,
                },
            },
        };
    }

    /// The most the plugins' work held at once since `fresh`, in bytes.
    pub fn peak_bytes(memory: *const Memory) u64 {
        std.debug.assert(memory.held.pages <= memory.held.buffer.len / page_bytes);

        return @as(u64, memory.held.pages) * page_bytes;
    }

    /// A new measure begins, when nothing is held: every page is new again.
    pub fn fresh(memory: *Memory) void {
        std.debug.assert(memory.held.pages <= memory.held.buffer.len / page_bytes);

        if (memory.open == 0) {
            std.debug.assert(memory.runs.free_pages() == memory.held.pages);

            memory.held.pages = 0;
            memory.runs.first = null;
            memory.begun = 0;
            memory.largest_name = "";
            memory.largest_bytes = 0;
        }
    }

    /// A plugin's collection named `name` holds `held` bytes: kept when the largest so far.
    pub fn note_largest(memory: *Memory, comptime name: []const u8, held: u64) void {
        comptime std.debug.assert(name.len > 0);

        if (held > memory.largest_bytes) {
            memory.largest_bytes = held;
            memory.largest_name = name;
        }

        std.debug.assert(memory.largest_bytes >= held);
    }

    /// Whether `address` lies in the plugins' memory.
    pub fn holds(memory: *const Memory, address: u64) bool {
        const base = @intFromPtr(memory.held.buffer.ptr);

        std.debug.assert(memory.held.buffer.len > 0);

        return address >= base and address < base + memory.held.buffer.len;
    }
};

/// Whether `candidate` is a piece of work's memory: given back before the request ends.
pub fn is_work(candidate: std.mem.Allocator) bool {
    var probe: Arena = .{
        .runs = undefined,
    };

    std.debug.assert(probe.blocks == null);

    return candidate.vtable == probe.allocator().vtable;
}

pub const Work = @import("plugin_memory/work.zig").Work;

test "the plugins' memory is whole pages of its buffer, and a piece of work's is known" {
    const buffer = try std.testing.allocator.alignedAlloc(u8, alignment, 4 * page_bytes);
    defer std.testing.allocator.free(buffer);

    var memory: Memory = undefined;

    memory.init(buffer);

    var arena: Arena = .{
        .runs = &memory.runs,
    };
    const taken = try arena.allocator().alloc(u8, 3 * page_bytes);

    try std.testing.expect(is_work(arena.allocator()));
    try std.testing.expect(!is_work(std.testing.allocator));
    try std.testing.expect(memory.holds(@intFromPtr(taken.ptr)));
    try std.testing.expect(!memory.holds(@intFromPtr(&memory)));
    try std.testing.expectEqual(@as(u64, 4 * page_bytes), memory.peak_bytes());
    try std.testing.expectError(error.OutOfMemory, arena.allocator().alloc(u8, page_bytes));

    arena.deinit();
    memory.fresh();
    try std.testing.expectEqual(@as(u64, 0), memory.peak_bytes());
}
