//! What the library's explorer and band draw, worked out from `media list` and the filter:
//! every link, label and flag, the same way `MediaLibrary.ptsx` works them out in the
//! browser after a change, so the markup only reads fields.

const std = @import("std");
const media = @import("../../../operations/media.zig");

pub const page_size: u32 = 25;
const depth_max: u32 = 5;
const month_names = [_][]const u8{
    "",       "January",   "February", "March",    "April",    "May", "June", "July",
    "August", "September", "October",  "November", "December",
};

pub const Filter = struct {
    folder: []const u8 = "",
    tags: []const []const u8 = &.{},
    search: []const u8 = "",
    year: u32 = 0,
    month: u32 = 0,
    page: u32 = 1,
    /// The bar's filters on the file itself: empty while not in the bar, `any` in it at Any,
    /// else the value (`image`, `large`, `private`).
    kind: []const u8 = "",
    size: []const u8 = "",
    visibility: []const u8 = "",
};

/// A bar filter's value for `media list`: empty unless one is chosen.
pub fn chosen(value: []const u8) []const u8 {
    return if (std.mem.eql(u8, value, "any")) "" else value;
}

/// The library's address for a filter: `/admin/media?folder=…&tag=…&search=…`.
pub fn href_of(arena: std.mem.Allocator, filter: Filter) ![]const u8 {
    std.debug.assert(filter.page >= 1);
    std.debug.assert(filter.month <= 12);

    var text: std.ArrayList(u8) = .empty;

    try text.appendSlice(arena, "/admin/media");

    if (filter.folder.len > 0) {
        try pair(arena, &text, "folder", filter.folder);
    }

    for (filter.tags) |tag| {
        try pair(arena, &text, "tag", tag);
    }

    if (filter.search.len > 0) {
        try pair(arena, &text, "search", filter.search);
    }

    if (filter.year > 0) {
        try pair(arena, &text, "year", try std.fmt.allocPrint(arena, "{d}", .{filter.year}));

        if (filter.month > 0) {
            try pair(arena, &text, "month", try std.fmt.allocPrint(arena, "{d}", .{filter.month}));
        }
    }

    if (filter.kind.len > 0) {
        try pair(arena, &text, "type", filter.kind);
    }

    if (filter.size.len > 0) {
        try pair(arena, &text, "size", filter.size);
    }

    if (filter.visibility.len > 0) {
        try pair(arena, &text, "visibility", filter.visibility);
    }

    if (filter.page > 1) {
        try pair(arena, &text, "page", try std.fmt.allocPrint(arena, "{d}", .{filter.page}));
    }

    return text.items;
}

fn pair(
    arena: std.mem.Allocator,
    text: *std.ArrayList(u8),
    name: []const u8,
    value: []const u8,
) !void {
    std.debug.assert(name.len > 0);
    std.debug.assert(text.items.len > 0);

    const first = std.mem.indexOfScalar(u8, text.items, '?') == null;

    try text.append(arena, if (first) '?' else '&');
    try text.appendSlice(arena, name);
    try text.append(arena, '=');

    for (value) |char| {
        if (std.ascii.isAlphanumeric(char) or char == '-' or char == '_' or char == '.') {
            try text.append(arena, char);
        } else if (char == ' ') {
            try text.append(arena, '+');
        } else {
            try text.print(arena, "%{X:0>2}", .{char});
        }
    }
}

/// `1.2 MB`, `640 KB`, `12 B`.
pub fn size_text(arena: std.mem.Allocator, bytes: u64) ![]const u8 {
    std.debug.assert(bytes <= std.math.maxInt(u53));

    const mega: u64 = 1024 * 1024;

    if (bytes >= mega) {
        const tenths = (bytes * 10 + mega / 2) / mega;

        return std.fmt.allocPrint(arena, "{d}.{d} MB", .{ tenths / 10, tenths % 10 });
    }

    if (bytes >= 1024) {
        return std.fmt.allocPrint(arena, "{d} KB", .{(bytes + 512) / 1024});
    }

    return std.fmt.allocPrint(arena, "{d} B", .{bytes});
}

/// A file's type as people say it, from its name: `PDF`, `MP4`.
pub fn kind_of(arena: std.mem.Allocator, filename: []const u8) ![]const u8 {
    std.debug.assert(filename.len > 0);

    const dot = std.mem.lastIndexOfScalar(u8, filename, '.') orelse filename.len;
    const kind = try std.ascii.allocUpperString(arena, filename[@min(dot + 1, filename.len)..]);

    std.debug.assert(kind.len < filename.len);

    return kind;
}

/// `JPG · 2400 × 1600 · 1.2 MB`.
pub fn facts_of(arena: std.mem.Allocator, item: media.Item) ![]const u8 {
    std.debug.assert(item.filename.len > 0);

    const dot = std.mem.lastIndexOfScalar(u8, item.filename, '.') orelse item.filename.len;
    const extension = item.filename[@min(dot + 1, item.filename.len)..];
    const upper = try std.ascii.allocUpperString(arena, extension);
    const size = try size_text(arena, item.size);

    if (item.width) |width| {
        return std.fmt.allocPrint(arena, "{s} · {d} × {d} · {s}", .{
            upper, width, item.height orelse 0, size,
        });
    }

    return std.fmt.allocPrint(arena, "{s} · {s}", .{ upper, size });
}

pub fn month_name(month: u32) []const u8 {
    std.debug.assert(month_names.len == 13);

    return if (month <= 12) month_names[month] else "";
}

pub fn icon_of(family: []const u8) []const u8 {
    std.debug.assert(family.len > 0);

    if (std.mem.eql(u8, family, "video")) {
        return "video";
    }

    return if (std.mem.eql(u8, family, "audio")) "audio" else "file";
}

/// The tags with one taken out, or put in when missing.
pub fn toggled(
    arena: std.mem.Allocator,
    tags: []const []const u8,
    id: []const u8,
) ![]const []const u8 {
    std.debug.assert(id.len > 0);

    var next: std.ArrayList([]const u8) = .empty;
    var found = false;

    for (tags) |tag| {
        if (std.mem.eql(u8, tag, id)) {
            found = true;
        } else {
            try next.append(arena, tag);
        }
    }

    if (!found) {
        try next.append(arena, id);
    }

    return next.items;
}

pub fn contains(tags: []const []const u8, id: []const u8) bool {
    std.debug.assert(id.len > 0);

    for (tags) |tag| {
        if (std.mem.eql(u8, tag, id)) {
            return true;
        }
    }

    return false;
}

pub fn depth_level(depth: u32) []const u8 {
    const levels = [_][]const u8{ "1", "2", "3", "4", "5" };

    std.debug.assert(levels.len == depth_max);

    return levels[@min(depth, depth_max - 1)];
}

pub fn nests(depth: u32) bool {
    std.debug.assert(depth_max > 1);

    return depth < depth_max - 1;
}

test "href_of: the filter in the server's order, escaped, defaults left out" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("/admin/media", try href_of(arena, .{}));
    try std.testing.expectEqualStrings(
        "/admin/media?folder=f1&tag=t1&tag=t2&search=old+boat%26sea&year=2026&month=3&page=2",
        try href_of(arena, .{
            .folder = "f1",
            .tags = &.{ "t1", "t2" },
            .search = "old boat&sea",
            .year = 2026,
            .month = 3,
            .page = 2,
        }),
    );
    try std.testing.expectEqualStrings("/admin/media?search=x", try href_of(arena, .{
        .search = "x",
        .month = 4,
    }));
}

test "size_text and facts_of read as the browser writes them" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("12 B", try size_text(arena, 12));
    try std.testing.expectEqualStrings("640 KB", try size_text(arena, 640 * 1024));
    try std.testing.expectEqualStrings("1.2 MB", try size_text(arena, 1_258_291));

    var item = media.library.example_item;

    try std.testing.expectEqualStrings("JPG · 2400 × 1600 · 471 KB", try facts_of(arena, item));
    item.width = null;
    try std.testing.expectEqualStrings("JPG · 471 KB", try facts_of(arena, item));
}
