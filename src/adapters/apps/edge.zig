//! A CDN in front, purged surgically. Every built page and static island carries the
//! dependency keys its build recorded as `Cache-Tag`; every request that writes answers with
//! the keys it raised, `X-Publr-Changed`. Whatever purges the CDN (Publr Cloud's router)
//! purges exactly those tags, so the edge drops exactly what the site rebuilds on disk, and
//! nothing else. Only with `--edge-max-age`: without a CDN that purges, neither header is
//! sent.
//!
//! A key is a tag as it is, when it is plain (letters, digits and `._:/-`); any other byte
//! is written `%XX`, the same both ways, so a tag and its purge always match.

const std = @import("std");
const http = @import("../../lib/http.zig");
const App = @import("state.zig").App;
const Project = @import("../../server/project.zig").Project;
const artifacts = @import("artifacts.zig");

/// The tag every artifact without keys carries (the 404 page, a page whose keys cannot be
/// told): any change purges it, as every changed-keys answer names it too.
pub const any_tag = "any";
/// Changed keys past this many are `*`: purge the whole site.
pub const changed_max: u32 = 900;
/// Cloudflare's limit for one response's tags is 16 KB; kept under it.
pub const tags_bytes_max: u32 = 15_000;
pub const changed_header = "X-Publr-Changed";

/// A built file's `Cache-Tag`: the keys the app's page or island at `url` recorded when it
/// was built, or `any` when it has none (or null: the 404 page, never indexed) or they
/// would not fit.
pub fn tag(
    response: *http.Response,
    app: *App,
    arena: std.mem.Allocator,
    url: ?[]const u8,
) !void {
    std.debug.assert(app.css.len > 0);

    if (app.options.edge_max_age == 0) {
        return;
    }

    const inside = url orelse return response.set_header("Cache-Tag", any_tag);
    const name = try artifacts.name(arena, app, inside);
    const keys = app.index.keys_of(arena, name) catch &.{};
    const value = try joined(arena, keys, tags_bytes_max) orelse any_tag;

    try response.set_header("Cache-Tag", value);
}

/// Router middleware: a request that may write (anything but a read) answers with the keys
/// it raised, as tags: empty when it changed nothing a page depends on, `*` when too many
/// changed to name.
pub fn changes(
    request: *http.Request,
    response: *http.Response,
    ctx: *http.Context,
    next: http.Router.Next,
) anyerror!void {
    std.debug.assert(ctx.user_data != null);

    const project = Project.of(ctx);

    if (project.apps.len == 0) {
        return next.run(request, response, ctx);
    }

    const app = &project.apps[0];
    const read = switch (request.method()) {
        .get, .head, .options => true,
        else => false,
    };

    if (read or app.options.edge_max_age == 0) {
        return next.run(request, response, ctx);
    }

    const before = try app.index.revision();

    try next.run(request, response, ctx);

    const since = try app.index.changes_since(response.arena, before);
    const value = if (since.reset or since.keys.len > changed_max)
        "*"
    else
        try joined(response.arena, since.keys, std.math.maxInt(u32)) orelse "*";

    try response.set_header(changed_header, value);
}

/// Keys as tags, comma-separated; null when they would pass `bytes_max`.
fn joined(arena: std.mem.Allocator, keys: []const []const u8, bytes_max: u32) !?[]const u8 {
    std.debug.assert(bytes_max > 0);

    if (keys.len == 0) {
        return "";
    }

    var out: std.Io.Writer.Allocating = .init(arena);

    for (keys, 0..) |key, index| {
        if (index > 0) {
            try out.writer.writeByte(',');
        }

        try write_tag(&out.writer, key);

        if (out.written().len > bytes_max) {
            return null;
        }
    }

    return out.written();
}

pub fn write_tag(writer: *std.Io.Writer, key: []const u8) !void {
    std.debug.assert(key.len > 0);

    for (key) |byte| {
        const plain = std.ascii.isAlphanumeric(byte) or
            std.mem.indexOfScalar(u8, "._:/-", byte) != null;

        if (plain) {
            try writer.writeByte(byte);
        } else {
            try writer.print("%{X:0>2}", .{byte});
        }
    }
}

test "keys become tags, the same way every time" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const keys = [_][]const u8{ "record:9f2c", "type:post", "template:content/my page.publr" };
    const value = (try joined(arena, &keys, 1000)).?;

    try std.testing.expectEqualStrings(
        "record:9f2c,type:post,template:content/my%20page.publr",
        value,
    );
    try std.testing.expectEqualStrings("", (try joined(arena, &.{}, 1000)).?);
    try std.testing.expect(try joined(arena, &keys, 20) == null);

    // A comma inside a key never splits it.
    const odd = (try joined(arena, &.{"a,b"}, 1000)).?;
    try std.testing.expectEqualStrings("a%2Cb", odd);
}
