const std = @import("std");
const App = @import("state.zig").App;

pub const page_bytes_max: u32 = 8 << 20;
pub const path_len_max: u32 = 1024;

/// A built page or static island as the dependency index knows it: `<app>:<url>`, so the
/// same URL in two apps is two artifacts.
pub fn name(arena: std.mem.Allocator, app: *const App, url: []const u8) ![]const u8 {
    std.debug.assert(url.len > 0);
    std.debug.assert(url[0] == '/');

    return std.fmt.allocPrint(arena, "{s}:{s}", .{ app.spec.name, url });
}

/// An artifact's app and URL; null for a name no app wrote.
pub const Parts = struct { app: []const u8, url: []const u8 };

pub fn split(artifact: []const u8) ?Parts {
    std.debug.assert(artifact.len > 0);

    const colon = std.mem.indexOfScalar(u8, artifact, ':') orelse return null;

    if (colon == 0 or colon + 1 >= artifact.len or artifact[colon + 1] != '/') {
        return null;
    }

    return .{ .app = artifact[0..colon], .url = artifact[colon + 1 ..] };
}

/// Writes `data` at `path` inside the app's output folder, making the folders it needs.
pub fn write(app: *const App, path: []const u8, data: []const u8) !void {
    std.debug.assert(path.len > 0);
    std.debug.assert(app.output != null);

    if (path.len > path_len_max) {
        return error.NameTooLong;
    }

    const out = app.output.?;

    if (std.mem.lastIndexOfScalar(u8, path, '/')) |cut| {
        try out.createDirPath(app.io, path[0..cut]);
    }

    try out.writeFile(app.io, .{ .sub_path = path, .data = data });
}

/// A built page for `serve`, or null when it was never built.
pub fn built_page(app: *const App, arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
    std.debug.assert(path.len > 0);
    std.debug.assert(page_bytes_max > 0);

    const out = app.output orelse return null;

    if (std.mem.indexOf(u8, path, "/.") != null) {
        return null;
    }

    const file = page_path(arena, path) catch return null;

    return out.readFileAlloc(app.io, file, arena, .limited(page_bytes_max)) catch null;
}

/// A built static island for `serve`, or null when it was never built.
pub fn built_island(app: *const App, arena: std.mem.Allocator, key: []const u8) ?[]const u8 {
    std.debug.assert(key.len > 0);
    std.debug.assert(page_bytes_max > 0);

    const out = app.output orelse return null;
    const file = island_path(arena, key) catch return null;

    return out.readFileAlloc(app.io, file, arena, .limited(page_bytes_max)) catch null;
}

pub fn built_404(app: *const App, arena: std.mem.Allocator) ?[]const u8 {
    std.debug.assert(page_bytes_max > 0);
    std.debug.assert(app.css.len > 0);

    const out = app.output orelse return null;

    return out.readFileAlloc(app.io, "404.html", arena, .limited(page_bytes_max)) catch null;
}

/// "/posts/hello" is "posts/hello/index.html"; "/" is "index.html".
pub fn page_path(arena: std.mem.Allocator, url: []const u8) ![]const u8 {
    std.debug.assert(url.len > 0);
    std.debug.assert(url[0] == '/');

    if (url.len <= 1) {
        return "index.html";
    }

    return std.fmt.allocPrint(arena, "{s}/index.html", .{url[1..]});
}

/// "latest-posts" is "_islands/latest-posts.html".
pub fn island_path(arena: std.mem.Allocator, key: []const u8) ![]const u8 {
    std.debug.assert(key.len > 0);
    std.debug.assert(std.mem.indexOfScalar(u8, key, '/') == null);

    return std.fmt.allocPrint(arena, "_islands/{s}.html", .{key});
}

test "artifact file paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("index.html", try page_path(arena, "/"));
    const post = try page_path(arena, "/posts/hello");
    try std.testing.expectEqualStrings("posts/hello/index.html", post);
    const island = try island_path(arena, "latest-posts");
    try std.testing.expectEqualStrings("_islands/latest-posts.html", island);
}

test "an artifact's name splits into its app and its URL" {
    const parts = split("www:/posts/hello").?;

    try std.testing.expectEqualStrings("www", parts.app);
    try std.testing.expectEqualStrings("/posts/hello", parts.url);
    try std.testing.expectEqualStrings("/", split("docs:/").?.url);
    try std.testing.expect(split("/posts/hello") == null);
    try std.testing.expect(split(":/x") == null);
    try std.testing.expect(split("www:") == null);
    try std.testing.expect(split("www:x") == null);
}
