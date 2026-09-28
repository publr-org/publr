//! The route table a theme's `content/` tree declares, and how a request path is
//! matched against it.

const std = @import("std");
const compile = @import("compile.zig");

pub const RouteKind = enum { static, dynamic, catch_all };

pub const Route = struct {
    /// In the router's syntax: "/posts/:slug", "/docs/*".
    pattern: []const u8,
    kind: RouteKind,
    template: u32,
    /// The page reads `Publr.request`: rendered per request, never built.
    live: bool,
};

/// A route matched against a path: the route and its `:slug`.
pub const Match = struct { route: *const Route, slug: ?[]const u8 = null };

pub const pattern_len_max: u32 = 1024;

/// "content/posts/[slug].publr" becomes "/posts/:slug"; "content/index.publr" becomes
/// "/"; "content/docs/[...path].publr" becomes "/docs/*".
pub fn route_pattern(arena: std.mem.Allocator, rel: []const u8) ![]const u8 {
    std.debug.assert(std.mem.startsWith(u8, rel, "content/"));
    std.debug.assert(std.mem.endsWith(u8, rel, ".publr"));

    const stem = compile.stem_of(rel)["content/".len..];
    var out: std.Io.Writer.Allocating = .init(arena);
    var segments = std.mem.splitScalar(u8, stem, '/');

    while (segments.next()) |segment| {
        if (segment.len == 0) {
            continue;
        }

        if (std.mem.eql(u8, segment, "index") and segments.peek() == null) {
            continue;
        }

        try out.writer.writeByte('/');
        try write_segment(&out.writer, segment);
    }

    const pattern = out.written();

    return if (pattern.len == 0) "/" else pattern;
}

fn write_segment(writer: *std.Io.Writer, segment: []const u8) !void {
    std.debug.assert(segment.len > 0);

    const bracketed = segment.len > 2 and segment[0] == '[' and segment[segment.len - 1] == ']';

    if (!bracketed) {
        return writer.writeAll(segment);
    }

    const inner = segment[1 .. segment.len - 1];

    std.debug.assert(inner.len > 0);

    if (std.mem.startsWith(u8, inner, "...")) {
        try writer.writeByte('*');
    } else {
        try writer.writeByte(':');
        try writer.writeAll(inner);
    }
}

pub fn route_kind(pattern: []const u8) RouteKind {
    std.debug.assert(pattern.len > 0);
    std.debug.assert(pattern[0] == '/');

    if (std.mem.indexOfScalar(u8, pattern, '*') != null) {
        return .catch_all;
    }

    if (std.mem.indexOfScalar(u8, pattern, ':') != null) {
        return .dynamic;
    }

    return .static;
}

/// Static before dynamic before catch-all, then by pattern.
pub fn route_less_than(_: void, left: Route, right: Route) bool {
    std.debug.assert(left.pattern.len > 0);
    std.debug.assert(right.pattern.len > 0);

    if (left.kind != right.kind) {
        return @intFromEnum(left.kind) < @intFromEnum(right.kind);
    }

    return std.mem.lessThan(u8, left.pattern, right.pattern);
}

/// Whether `path` is an instance of `pattern`; the `:param` segment's value when the
/// pattern has one. A trailing `*` matches the rest of the path.
pub fn match_pattern(pattern: []const u8, path: []const u8) ??[]const u8 {
    std.debug.assert(pattern.len > 0);
    std.debug.assert(pattern[0] == '/');

    if (path.len == 0 or path[0] != '/') {
        return null;
    }

    var expected = std.mem.splitScalar(u8, pattern[1..], '/');
    var actual = std.mem.splitScalar(u8, path[1..], '/');
    var slug: ?[]const u8 = null;

    while (expected.next()) |segment| {
        if (std.mem.eql(u8, segment, "*")) {
            return slug;
        }

        const part = actual.next() orelse return null;

        if (segment.len > 1 and segment[0] == ':') {
            if (part.len == 0) {
                return null;
            }

            slug = part;
        } else if (!std.mem.eql(u8, segment, part)) {
            return null;
        }
    }

    return if (actual.next() == null) slug else null;
}

/// "/posts/:slug" + "hello" becomes "/posts/hello".
pub fn substitute(arena: std.mem.Allocator, pattern: []const u8, slug: []const u8) ![]const u8 {
    std.debug.assert(pattern.len > 0);
    std.debug.assert(pattern.len <= pattern_len_max);

    var out: std.Io.Writer.Allocating = .init(arena);
    var index: u32 = 0;

    while (index < pattern.len) {
        if (pattern[index] == ':') {
            index += 1;

            while (index < pattern.len and pattern[index] != '/') index += 1;

            try out.writer.writeAll(slug);
        } else {
            try out.writer.writeByte(pattern[index]);
            index += 1;
        }
    }

    return out.written();
}

test "route patterns follow the content/ tree, index dropped, [x] to :x, [...x] to *" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const expect = std.testing.expectEqualStrings;

    try expect("/", try route_pattern(arena, "content/index.publr"));
    try expect("/about", try route_pattern(arena, "content/about.publr"));
    try expect("/posts", try route_pattern(arena, "content/posts/index.publr"));
    try expect("/posts/:slug", try route_pattern(arena, "content/posts/[slug].publr"));
    try expect("/docs/*", try route_pattern(arena, "content/docs/[...path].publr"));
    try expect("/fresh", try route_pattern(arena, "content/fresh.dynamic.publr"));
    try expect("/posts", try route_pattern(arena, "content/posts/index.dynamic.publr"));
    try std.testing.expectEqual(RouteKind.dynamic, route_kind("/posts/:slug"));
    try std.testing.expectEqual(RouteKind.catch_all, route_kind("/docs/*"));
    try std.testing.expectEqual(RouteKind.static, route_kind("/posts"));

    try expect("/posts/hello", try substitute(arena, "/posts/:slug", "hello"));
    try expect("hello", (match_pattern("/posts/:slug", "/posts/hello").?).?);
    try std.testing.expect(match_pattern("/posts/:slug", "/posts") == null);
    try std.testing.expect(match_pattern("/posts/:slug", "/posts/") == null);
    try std.testing.expect(match_pattern("/posts/:slug", "/pages/hello") == null);
    try std.testing.expect(match_pattern("/posts/:slug", "posts/hello") == null);
    try std.testing.expect((match_pattern("/", "/").?) == null);
    try std.testing.expect(match_pattern("/", "/x") == null);
    try std.testing.expect(match_pattern("/docs/*", "/docs/a/b") != null);
}

test "routes sort static, then dynamic, then catch-all, each by pattern" {
    var routes = [_]Route{
        .{ .pattern = "/docs/*", .kind = .catch_all, .template = 0, .live = false },
        .{ .pattern = "/posts/:slug", .kind = .dynamic, .template = 1, .live = false },
        .{ .pattern = "/posts", .kind = .static, .template = 2, .live = false },
        .{ .pattern = "/", .kind = .static, .template = 3, .live = false },
    };
    std.mem.sort(Route, &routes, {}, route_less_than);
    try std.testing.expectEqualStrings("/", routes[0].pattern);
    try std.testing.expectEqualStrings("/posts", routes[1].pattern);
    try std.testing.expectEqualStrings("/posts/:slug", routes[2].pattern);
    try std.testing.expectEqualStrings("/docs/*", routes[3].pattern);
}
