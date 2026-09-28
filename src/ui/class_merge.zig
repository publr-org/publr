//! The render runtime's one seam: a stack of `class` attributes merged into one class
//! list by the JIT's Tailwind-aware resolver, so a later conflicting utility wins
//! (`max-w-xl` after `max-w-md` removes the earlier one). The theme is the admin
//! sheet's theme, so the design system's scale tokens resolve as the utilities they
//! are. A fixed heap caches results; uncached merges and resolver temporaries live
//! in the render arena, so cache pressure never drops styles.
const std = @import("std");
const jit = @import("publr_jit");

const ui_theme: jit.Theme = @import("ui_theme");
const theme: jit.Theme = jit.extendTheme(jit.default_theme, ui_theme);

const heap_bytes = 1 << 20;
const key_bytes_max = 4 << 10;

// The memo lives for the process: the server is single-threaded, and the heap is
// fixed at startup, never grown (STYLE: all memory at startup, bounded).
var heap: [heap_bytes]u8 = undefined;
// The allocator over that heap; process-global for the same reason.
var heap_state: std.heap.FixedBufferAllocator = .init(&heap);
// The memo itself, keyed by the joined parts; process-global for the same reason.
var memo: std.StringHashMapUnmanaged([]const u8) = .empty;

/// Cached results live for the process; uncached results live in the caller's render
/// arena. Exhausting the memo must never change the markup or conflict resolution.
pub fn merge_classes(arena: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    std.debug.assert(parts.len <= 64);
    std.debug.assert(heap_bytes > key_bytes_max);

    var key_buffer: [key_bytes_max]u8 = undefined;
    const key = key_of(parts, &key_buffer);

    if (key) |value| {
        if (memo.get(value)) |hit| return hit;
    }

    // Resolver temporaries belong to this render, never to the permanent memo heap.
    const merged = try jit.mergeClasses(arena, theme, parts);

    if (key) |value| {
        return remember(value, merged) catch merged;
    }

    return merged;
}

fn remember(key: []const u8, merged: []const u8) ![]const u8 {
    std.debug.assert(key.len <= key_bytes_max);
    std.debug.assert(heap_state.end_index <= heap_bytes);

    const before = heap_state.end_index;
    errdefer heap_state.end_index = before;
    const allocator = heap_state.allocator();
    const kept_key = try allocator.dupe(u8, key);
    const kept_value = try allocator.dupe(u8, merged);
    try memo.put(allocator, kept_key, kept_value);
    return kept_value;
}

/// The parts joined with NUL, a byte no class attribute carries, so `["a b", "c"]` and
/// `["a", "b c"]` key differently; null when the stack is too long to memoise.
fn key_of(parts: []const []const u8, buffer: []u8) ?[]const u8 {
    std.debug.assert(buffer.len == key_bytes_max);
    std.debug.assert(parts.len <= 64);

    var length: usize = 0;

    for (parts) |part| {
        if (length + part.len + 1 > buffer.len) {
            return null;
        }

        @memcpy(buffer[length .. length + part.len], part);
        length += part.len;
        buffer[length] = 0;
        length += 1;
    }

    return buffer[0..length];
}

test "a later conflicting utility wins the merge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const merged = try merge_classes(arena.allocator(), &.{ "max-w-md px-4", "max-w-xl" });
    try std.testing.expect(std.mem.indexOf(u8, merged, "max-w-md") == null);
    try std.testing.expect(std.mem.indexOf(u8, merged, "max-w-xl") != null);
    try std.testing.expect(std.mem.indexOf(u8, merged, "px-4") != null);
}

test "design-system scale tokens resolve as font-size utilities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const merged = try merge_classes(arena.allocator(), &.{ "text-body-sm", "text-xs" });
    try std.testing.expect(std.mem.indexOf(u8, merged, "text-body-sm") == null);
    try std.testing.expect(std.mem.indexOf(u8, merged, "text-xs") != null);
}

test "the same stack is answered from the memo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const first = try merge_classes(arena.allocator(), &.{ "flex", "gap-2" });
    const second = try merge_classes(arena.allocator(), &.{ "flex", "gap-2" });
    try std.testing.expect(first.ptr == second.ptr);
}

test "new class stacks keep their styles after the memo fills" {
    const before = heap_state.end_index;
    heap_state.end_index = heap_bytes;
    defer heap_state.end_index = before;

    var buffer: [64]u8 = undefined;

    for (0..2000) |index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const unique = try std.fmt.bufPrint(&buffer, "record-{d}", .{index});
        const merged = try merge_classes(arena.allocator(), &.{ "flex px-4", unique, "px-8" });
        try std.testing.expect(std.mem.indexOf(u8, merged, "flex") != null);
        try std.testing.expect(std.mem.indexOf(u8, merged, unique) != null);
        try std.testing.expect(std.mem.indexOf(u8, merged, "px-8") != null);
        try std.testing.expect(std.mem.indexOf(u8, merged, "px-4") == null);
    }
}

test "cached classes survive the render arena that first merged them" {
    {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const part = try arena.allocator().dupe(u8, "cache-lifetime flex px-2");
        _ = try merge_classes(arena.allocator(), &.{ part, "px-6" });
    }
    const hit = try merge_classes(std.testing.failing_allocator, &.{
        "cache-lifetime flex px-2", "px-6",
    });
    try std.testing.expectEqualStrings("cache-lifetime flex px-6", hit);
}

test "class stacks too long to cache still merge and report allocation failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const long = [_]u8{'a'} ** key_bytes_max;
    const merged = try merge_classes(arena.allocator(), &.{ &long, "px-2", "px-6" });
    try std.testing.expect(std.mem.startsWith(u8, merged, &long));
    try std.testing.expect(std.mem.endsWith(u8, merged, " px-6"));
    try std.testing.expect(std.mem.indexOf(u8, merged, "px-2") == null);
    try std.testing.expectError(error.OutOfMemory, merge_classes(
        std.testing.failing_allocator,
        &.{ &long, "px-2", "px-6" },
    ));
}
