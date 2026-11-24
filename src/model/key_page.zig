//! A page of a list held in memory, in the order of its keys (a name, a path): the items
//! whose keys come after the last page's, at most a page of them, and the key the page after
//! starts from. What an operation answering a page at a time (`after` in, `next` out) reads
//! from a registry or a folder rather than from the database.
const std = @import("std");

/// Which items the page holds, `[start, end)` of the sorted list, and the next page's
/// `after`: empty after the last.
pub const Window = struct {
    start: u32,
    end: u32,
    next: []const u8,
};

/// The page of `keys` (sorted, each once) after `after`, at most `limit` of them.
pub fn window(keys: []const []const u8, after: []const u8, limit: u32) Window {
    std.debug.assert(limit > 0);
    std.debug.assert(keys.len <= std.math.maxInt(u32));

    const start = if (after.len == 0) 0 else first_after(keys, after);
    const end: u32 = @intCast(@min(keys.len, @as(u64, start) + limit));

    std.debug.assert(start <= end);

    return .{
        .start = start,
        .end = end,
        .next = if (end < keys.len and end > start) keys[end - 1] else "",
    };
}

/// Where the first key past `after` lies: halved each step, so a page costs the log of the
/// list, never its length.
fn first_after(keys: []const []const u8, after: []const u8) u32 {
    std.debug.assert(after.len > 0);

    var low: u32 = 0;
    var high: u32 = @intCast(keys.len);

    while (low < high) {
        const middle = low + (high - low) / 2;

        if (std.mem.order(u8, keys[middle], after) == .gt) {
            high = middle;
        } else {
            low = middle + 1;
        }
    }

    std.debug.assert(low <= keys.len);

    return low;
}

/// Whether `left` sorts before `right`: what callers sort their items by before a window.
pub fn before(left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

test "a window takes the keys after the last page's, and names where the next starts" {
    const keys = [_][]const u8{ "a", "b", "c", "d", "e" };

    const first = window(&keys, "", 2);

    try std.testing.expectEqual(@as(u32, 0), first.start);
    try std.testing.expectEqual(@as(u32, 2), first.end);
    try std.testing.expectEqualStrings("b", first.next);

    const second = window(&keys, first.next, 2);

    try std.testing.expectEqual(@as(u32, 2), second.start);
    try std.testing.expectEqualStrings("d", second.next);

    const last = window(&keys, second.next, 2);

    try std.testing.expectEqual(@as(u32, 4), last.start);
    try std.testing.expectEqual(@as(u32, 5), last.end);
    try std.testing.expectEqualStrings("", last.next);

    // A key no longer listed: the page starts where it would lie.
    const gone = window(&keys, "bb", 10);

    try std.testing.expectEqual(@as(u32, 2), gone.start);
    try std.testing.expectEqualStrings("", gone.next);

    const past = window(&keys, "z", 2);

    try std.testing.expectEqual(past.start, past.end);
    try std.testing.expect(before("a", "b") and !before("b", "a"));
}
