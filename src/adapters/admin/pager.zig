const std = @import("std");
const admin = @import("../admin.zig");

/// What a paged list's `Pager` shows: nothing when everything fits on one page.
pub const Links = struct {
    range: []const u8 = "",
    previous_href: []const u8 = "",
    next_href: []const u8 = "",
};

/// The page the request asks for: `?offset=`, 0 when missing or not a number.
pub fn offset_of(session: *const admin.Session) u32 {
    std.debug.assert(session.signed_in());

    const asked = admin.query_param(session, "offset") orelse return 0;

    return std.fmt.parseInt(u32, asked, 10) catch 0;
}

/// The links around the page of `shown` items from `offset`, of `total`, `size` a page, at
/// `path` (which carries its own query, if any).
pub fn links(
    arena: std.mem.Allocator,
    path: []const u8,
    offset: u32,
    shown: u32,
    total: u32,
    size: u32,
) error{OutOfMemory}!Links {
    std.debug.assert(size > 0);
    std.debug.assert(path.len > 0);

    if (total <= size and offset == 0) {
        return .{};
    }

    const joiner: []const u8 = if (std.mem.indexOfScalar(u8, path, '?') == null) "?" else "&";
    const end = offset + shown;

    return .{
        .range = if (shown == 0)
            try std.fmt.allocPrint(arena, "None past {d}", .{total})
        else
            try std.fmt.allocPrint(arena, "{d}–{d} of {d}", .{ offset + 1, end, total }),
        .previous_href = if (offset == 0)
            ""
        else
            try std.fmt.allocPrint(arena, "{s}{s}offset={d}", .{ path, joiner, offset -| size }),
        .next_href = if (end >= total)
            ""
        else
            try std.fmt.allocPrint(arena, "{s}{s}offset={d}", .{ path, joiner, end }),
    };
}

test "a page's links: none when all fits, the ends without the way past them" {
    var buffer: [1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const arena = fixed.allocator();

    try std.testing.expectEqualStrings("", (try links(arena, "/a", 0, 3, 3, 50)).range);

    const first = try links(arena, "/a", 0, 50, 120, 50);
    try std.testing.expectEqualStrings("1–50 of 120", first.range);
    try std.testing.expectEqualStrings("", first.previous_href);
    try std.testing.expectEqualStrings("/a?offset=50", first.next_href);

    const last = try links(arena, "/a?kept=1", 100, 20, 120, 50);
    try std.testing.expectEqualStrings("/a?kept=1&offset=50", last.previous_href);
    try std.testing.expectEqualStrings("", last.next_href);
}
