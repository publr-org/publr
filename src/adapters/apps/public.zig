//! An app's `public/` files, at their own paths under its mount: `public/robots.txt` is
//! `<mount>/robots.txt`. They bypass compilation, fingerprints and the page dependency
//! index. Every build copies them to the root of the app's build folder, so the folder
//! deploys as it is; `serve` answers them from `public/` itself.
const std = @import("std");
const http = @import("../../lib/http.zig");
const apps_adapter = @import("../apps.zig");
const state = @import("state.zig");
const media = @import("media.zig");

const Request = http.Request;
const Response = http.Response;
const HttpContext = http.Context;

const entries_max: u32 = 65_536;
const manifest_bytes_max: u32 = 16 << 20;

/// The public files the last build copied, one path per line, in the build folder: the
/// next build removes what left `public/` without touching the pages beside them.
pub const manifest_name = ".publr-public";

pub const Summary = struct { files: u32 = 0, bytes: u64 = 0 };

/// Copies `public/` to the root of the build folder, refusing a path the build writes
/// itself, and removes what an earlier build copied that is gone from `public/`.
pub fn sync(app: *const state.App) !Summary {
    std.debug.assert(app.output != null);
    std.debug.assert(app.spec.folder.len > 0);

    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const public_dir = try app.public_dir(arena);
    const target = app.output.?;
    const source = std.Io.Dir.cwd().openDir(app.io, public_dir, .{
        .iterate = true,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            try remove_gone(arena, app.io, target, &.{});
            return .{};
        },
        else => return err,
    };
    defer source.close(app.io);

    return copy_files(arena, app.io, source, target);
}

fn copy_files(
    arena: std.mem.Allocator,
    io: std.Io,
    source: std.Io.Dir,
    target: std.Io.Dir,
) !Summary {
    std.debug.assert(source.handle != target.handle);
    std.debug.assert(entries_max > 0);

    var walker = try source.walk(arena);
    defer walker.deinit();
    var copied: std.ArrayList([]const u8) = .empty;
    var summary: Summary = .{};
    var visited: u32 = 0;

    while (try walker.next(io)) |entry| {
        visited += 1;

        if (visited > entries_max) {
            return error.TooManyPublicFiles;
        }

        if (entry.kind != .file or hidden(entry.path) or is_stylesheet_input(entry.path)) {
            continue;
        }

        if (reserved(entry.path)) {
            return error.ReservedPublicFile;
        }

        try source.copyFile(entry.path, target, entry.path, io, .{ .make_path = true });
        const file = try source.openFile(io, entry.path, .{});
        defer file.close(io);

        summary.files += 1;
        summary.bytes += (try file.stat(io)).size;
        try copied.append(arena, try arena.dupe(u8, entry.path));
    }

    try remove_gone(arena, io, target, copied.items);

    std.debug.assert(summary.files == copied.items.len);

    return summary;
}

/// Deletes what the last manifest lists and `copied` does not, then records `copied`.
fn remove_gone(
    arena: std.mem.Allocator,
    io: std.Io,
    target: std.Io.Dir,
    copied: []const []const u8,
) !void {
    std.debug.assert(copied.len <= entries_max);
    std.debug.assert(manifest_name[0] == '.');

    const limit: std.Io.Limit = .limited(manifest_bytes_max);
    const read = target.readFileAlloc(io, manifest_name, arena, limit);
    const previous = read catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    var lines = std.mem.tokenizeScalar(u8, previous, '\n');

    while (lines.next()) |path| {
        if (contains(copied, path) or reserved(path) or hidden(path)) {
            continue;
        }

        target.deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    var listing: std.Io.Writer.Allocating = .init(arena);

    for (copied) |path| {
        try listing.writer.print("{s}\n", .{path});
    }

    try target.writeFile(io, .{ .sub_path = manifest_name, .data = listing.written() });
}

/// Answers `inside`, a path inside the app, with its public file, or with the build's
/// `sitemap.xml`; false when there is neither, for the caller's not-found.
pub fn serve(
    app: *const state.App,
    inside: []const u8,
    request: *Request,
    response: *Response,
    ctx: *HttpContext,
) !bool {
    std.debug.assert(inside.len > 0 and inside[0] == '/');
    std.debug.assert(request.method() == .get or request.method() == .head);

    if (@import("builtin").target.cpu.arch == .wasm32) {
        return false;
    }

    const path = inside[1..];

    if (std.mem.eql(u8, path, "sitemap.xml") and app.output != null) {
        const built = try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{
            app.options.output_dir,
            app.spec.name,
        });

        return serve_from(app, built, inside, response, ctx);
    }

    if (path.len == 0 or hidden(path) or reserved(path) or is_stylesheet_input(path)) {
        return false;
    }

    const root = try app.public_dir(ctx.arena);

    if (request.header("Range") != null) {
        return serve_range(app, root, path, request, response, ctx);
    }

    return serve_from(app, root, inside, response, ctx);
}

fn serve_from(
    app: *const state.App,
    root: []const u8,
    inside: []const u8,
    response: *Response,
    ctx: *HttpContext,
) !bool {
    std.debug.assert(root.len > 0);
    std.debug.assert(inside[0] == '/');

    const bytes_max = ctx.options.response_bytes_max;
    const result = try http.static.serve_file(root, inside, response, ctx.arena, bytes_max);

    switch (result) {
        .served => try apps_adapter.serve(response, app, .file, .{}),
        .not_found => return false,
        .too_large => try response.text(.internal_server_error, "file exceeds response cap"),
    }

    return true;
}

fn serve_range(
    app: *const state.App,
    root: []const u8,
    path: []const u8,
    request: *Request,
    response: *Response,
    ctx: *HttpContext,
) !bool {
    std.debug.assert(!hidden(path));
    std.debug.assert(request.header("Range") != null);

    const full = try std.fs.path.join(ctx.arena, &.{ root, path });
    const stat = std.Io.Dir.cwd().statFile(app.io, full, .{}) catch return false;

    if (stat.kind != .file) {
        return false;
    }

    try media.serve(request, response, ctx, app, root, path);

    return true;
}

/// What the build writes at the folder's root itself: generated assets, islands, pages,
/// the 404 page and the sitemap.
pub fn reserved(path: []const u8) bool {
    std.debug.assert(path.len > 0);
    std.debug.assert(path[0] != '/');

    const top = path[0 .. std.mem.indexOfScalar(u8, path, '/') orelse path.len];
    const cut = std.mem.lastIndexOfScalar(u8, path, '/');
    const basename = if (cut) |slash| path[slash + 1 ..] else path;
    const page = std.mem.eql(u8, basename, "index.html");

    return page or std.mem.eql(u8, top, "_app") or std.mem.eql(u8, top, "_islands") or
        std.mem.eql(u8, path, "404.html") or std.mem.eql(u8, path, "sitemap.xml");
}

/// `public/style.css` feeds the compiled stylesheet and is never a file of its own.
fn is_stylesheet_input(path: []const u8) bool {
    std.debug.assert(path.len > 0);
    std.debug.assert(path[0] != '/');

    return std.mem.eql(u8, path, "style.css");
}

fn hidden(path: []const u8) bool {
    std.debug.assert(path.len > 0);
    std.debug.assert(path[0] != '/');

    return path[0] == '.' or std.mem.indexOf(u8, path, "/.") != null;
}

fn contains(paths: []const []const u8, wanted: []const u8) bool {
    std.debug.assert(wanted.len > 0);
    std.debug.assert(paths.len <= entries_max);

    for (paths) |path| {
        if (std.mem.eql(u8, path, wanted)) {
            return true;
        }
    }

    return false;
}

test "public files copy to the build's root, and only what left public/ is removed" {
    const io = std.testing.io;
    var source = std.testing.tmpDir(.{ .iterate = true });
    defer source.cleanup();
    var target = std.testing.tmpDir(.{ .iterate = true });
    defer target.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try source.dir.createDir(io, "images", .default_dir);
    try source.dir.writeFile(io, .{ .sub_path = "images/logo.svg", .data = "first" });
    try source.dir.writeFile(io, .{ .sub_path = "robots.txt", .data = "User-agent: *" });
    try source.dir.writeFile(io, .{ .sub_path = "style.css", .data = "a{}" });
    try target.dir.writeFile(io, .{ .sub_path = "index.html", .data = "<p>page</p>" });

    const first = try copy_files(arena, io, source.dir, target.dir);
    try std.testing.expectEqual(@as(u32, 2), first.files);
    const robots = try target.dir.readFileAlloc(io, "robots.txt", arena, .limited(100));
    try std.testing.expectEqualStrings("User-agent: *", robots);
    try std.testing.expectError(error.FileNotFound, target.dir.access(io, "style.css", .{}));

    try source.dir.writeFile(io, .{ .sub_path = "images/logo.svg", .data = "replacement" });
    try source.dir.deleteFile(io, "robots.txt");
    _ = try copy_files(arena, io, source.dir, target.dir);
    const logo = try target.dir.readFileAlloc(io, "images/logo.svg", arena, .limited(100));
    try std.testing.expectEqualStrings("replacement", logo);
    try std.testing.expectError(error.FileNotFound, target.dir.access(io, "robots.txt", .{}));
    try target.dir.access(io, "index.html", .{});
}

test "a public file may not take a path the build writes itself" {
    try std.testing.expect(reserved("index.html"));
    try std.testing.expect(reserved("docs/index.html"));
    try std.testing.expect(reserved("404.html"));
    try std.testing.expect(reserved("sitemap.xml"));
    try std.testing.expect(reserved("_app/logo.svg"));
    try std.testing.expect(reserved("_islands/nav.html"));
    try std.testing.expect(!reserved("favicon.ico"));
    try std.testing.expect(!reserved("about.html"));
    try std.testing.expect(!reserved("assets/_app.svg"));
}
