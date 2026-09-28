//! An app's public files bypass compilation, fingerprints and the page dependency index.
//! Copy them on every build, including a build with no generated-page changes.
const std = @import("std");
const state = @import("state.zig");

const entries_max: u32 = 65_536;
pub const Summary = struct { files: u32 = 0, bytes: u64 = 0 };

pub fn sync(app: *const state.App) !Summary {
    std.debug.assert(app.output != null);
    std.debug.assert(app.assets.len <= state.assets_max);

    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const public_dir = try app.public_dir(arena_state.allocator());
    const source = std.Io.Dir.cwd().openDir(app.io, public_dir, .{
        .iterate = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer source.close(app.io);
    const target = try app.output.?.createDirPathOpen(app.io, "_app", .{
        .open_options = .{ .iterate = true },
    });
    defer target.close(app.io);

    return copy_files(arena_state.allocator(), app.io, source, target, app.assets);
}

fn copy_files(
    arena: std.mem.Allocator,
    io: std.Io,
    source: std.Io.Dir,
    target: std.Io.Dir,
    generated: []const state.Asset,
) !Summary {
    std.debug.assert(generated.len <= state.assets_max);
    std.debug.assert(source.handle != target.handle);

    var walker = try source.walk(arena);
    defer walker.deinit();
    var summary: Summary = .{};
    var visited: u32 = 0;

    while (try walker.next(io)) |entry| {
        visited += 1;

        if (visited > entries_max) {
            return error.TooManyPublicFiles;
        }
        if (entry.kind != .file or hidden(entry.path)) continue;
        if (std.mem.eql(u8, entry.path, "style.css")) continue;
        if (reserved(generated, entry.path)) {
            return error.ReservedAppAssetName;
        }

        try source.copyFile(entry.path, target, entry.path, io, .{ .make_path = true });
        const file = try source.openFile(io, entry.path, .{});
        defer file.close(io);

        summary.files += 1;
        summary.bytes += (try file.stat(io)).size;
    }

    try remove_missing(arena, io, source, target, generated);

    return summary;
}

fn remove_missing(
    arena: std.mem.Allocator,
    io: std.Io,
    source: std.Io.Dir,
    target: std.Io.Dir,
    generated: []const state.Asset,
) !void {
    std.debug.assert(generated.len <= state.assets_max);
    std.debug.assert(source.handle != target.handle);

    var walker = try target.walk(arena);
    defer walker.deinit();
    var visited: u32 = 0;

    while (try walker.next(io)) |entry| {
        visited += 1;

        if (visited > entries_max) {
            return error.TooManyPublicFiles;
        }
        if (entry.kind != .file or hidden(entry.path)) continue;
        if (reserved(generated, entry.path)) continue;

        const file = source.openFile(io, entry.path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try target.deleteFile(io, entry.path);
                continue;
            },
            else => return err,
        };
        file.close(io);
    }
}

fn reserved(generated: []const state.Asset, path: []const u8) bool {
    std.debug.assert(path.len > 0);
    std.debug.assert(generated.len <= state.assets_max);

    if (std.mem.eql(u8, path, @import("context.zig").stylesheet)) {
        return true;
    }

    for (generated) |file| {
        if (std.mem.eql(u8, file.path, path)) {
            return true;
        }
    }

    return false;
}

fn hidden(path: []const u8) bool {
    std.debug.assert(path.len > 0);
    std.debug.assert(path[0] != '/');

    return path[0] == '.' or std.mem.indexOf(u8, path, "/.") != null;
}

test "public files copy byte-for-byte, refresh without a cache, and remove stale files" {
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
    try source.dir.writeFile(io, .{ .sub_path = "raw.js", .data = "import './ref.js';" });
    const first = try copy_files(arena, io, source.dir, target.dir, &.{});
    try std.testing.expectEqual(@as(u32, 2), first.files);
    const script = try target.dir.readFileAlloc(io, "raw.js", arena, .limited(100));
    try std.testing.expectEqualStrings("import './ref.js';", script);

    try source.dir.writeFile(io, .{ .sub_path = "images/logo.svg", .data = "replacement" });
    try source.dir.deleteFile(io, "raw.js");
    _ = try copy_files(arena, io, source.dir, target.dir, &.{});
    const logo = try target.dir.readFileAlloc(io, "images/logo.svg", arena, .limited(100));
    try std.testing.expectEqualStrings("replacement", logo);
    try std.testing.expectError(error.FileNotFound, target.dir.openFile(io, "raw.js", .{}));
}
