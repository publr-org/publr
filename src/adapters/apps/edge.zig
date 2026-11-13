//! A CDN in front, purged by what was published. Everything a CDN may keep from an app
//! carries `Cache-Tag`: the app's name, and for a page, a static island, a public file or a
//! 404, the app's name with its path (`www:/posts/hello`). The dependency index logs what
//! the build published (a page or island whose bytes changed or that went away, a whole app
//! after its files changed); `GET /_publr/published?since=<revision>` reads that log, and
//! whatever purges the CDN (Publr Cloud's router) purges exactly those tags. So the edge
//! drops what changed on disk, only once it changed, however the change came: a write, a
//! queued job, a scheduled change, an app loaded. Only with `--edge-max-age`: without a
//! CDN, no tag is sent.
//!
//! A tag is the name as it is, when it is plain (letters, digits and `._:/-`); any other
//! byte is written `%XX`, the same both ways, so a tag and its purge always match.

const std = @import("std");
const http = @import("../../lib/http.zig");
const App = @import("state.zig").App;
const Project = @import("../../server/project.zig").Project;
const artifacts = @import("artifacts.zig");

pub const published_route = "/_publr/published";
/// A path's tag past this many bytes is left out: the app's tag alone purges it. Under what
/// a purger names in one tag (Publr Cloud keeps 256 bytes, the project's id included).
pub const tag_bytes_max: u32 = 200;

/// A response a CDN may keep: tagged with its app and, when it answers a path of the app
/// (a page, an island, a public file, a 404), that path too.
pub fn tag(
    response: *http.Response,
    app: *const App,
    arena: std.mem.Allocator,
    url: ?[]const u8,
) !void {
    std.debug.assert(app.spec.name.len > 0);

    if (app.options.edge_max_age == 0) {
        return;
    }

    var out: std.Io.Writer.Allocating = .init(arena);

    try write_tag(&out.writer, app.spec.name);

    const app_end = out.written().len;

    if (url) |path| {
        std.debug.assert(path.len > 0 and path[0] == '/');

        try out.writer.writeByte(',');
        try write_tag(&out.writer, try artifacts.name(arena, app, path));
    }

    // A path too long to be a tag: the app's tag alone still purges it.
    const too_long = out.written().len - app_end > tag_bytes_max + 1;
    const value = if (too_long) out.written()[0..app_end] else out.written();

    try response.set_header("Cache-Tag", value);
}

/// `GET /_publr/published?since=<revision>`: what was published after that revision, as
/// tags, `reset` when the log no longer reaches back so far (drop everything). Without
/// `since`, the revision alone: where a reader starts. Only public paths are named.
pub fn published(request: *http.Request, response: *http.Response, ctx: *http.Context) !void {
    std.debug.assert(ctx.user_data != null);
    std.debug.assert(request.method() == .get or request.method() == .head);

    const project = Project.of(ctx);
    const arena = response.arena;

    if (project.apps.len == 0) {
        return response.json(.ok, .{
            .revision = 0,
            .reset = false,
            .tags = &[_][]const u8{},
        });
    }

    const index = project.apps[0].index;
    const asked = http.Form.query_param(arena, request.query(), "since");
    const since = if (asked) |text| std.fmt.parseInt(u64, text, 10) catch null else null;

    if (since == null) {
        return response.json(.ok, .{
            .revision = try index.published_revision(),
            .reset = false,
            .tags = &[_][]const u8{},
        });
    }

    const found = try index.published_since(arena, since.?);
    const tags = try arena.alloc([]const u8, found.names.len);

    for (found.names, tags) |name, *each| {
        var out: std.Io.Writer.Allocating = .init(arena);

        try write_tag(&out.writer, name);
        each.* = out.written();
    }

    try response.json(.ok, .{
        .revision = found.revision,
        .reset = found.reset,
        .tags = tags,
    });
}

/// Every app of the project published whole: its files changed (templates, assets, public
/// files), so anything the edge keeps of it may be stale.
pub fn publish_apps(project: *const Project) void {
    std.debug.assert(project.apps.len <= 1024);
    std.debug.assert(project.connection.transaction_depth == 0);

    if (project.apps.len == 0 or project.apps[0].options.edge_max_age == 0) {
        return;
    }

    for (project.apps) |*app| {
        project.apps[0].index.publish(&.{app.spec.name}) catch |err| {
            std.log.warn("apps: {s} not published for the edge: {t}", .{ app.spec.name, err });
        };
    }
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

test "names become tags, the same way every time" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try write_tag(&out.writer, "www:/posts/my page");
    try std.testing.expectEqualStrings("www:/posts/my%20page", out.written());

    out.clearRetainingCapacity();

    // A comma inside a name never splits it.
    try write_tag(&out.writer, "a,b");
    try std.testing.expectEqualStrings("a%2Cb", out.written());
}
