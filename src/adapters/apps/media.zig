//! Bounded byte ranges let locally copied videos play without fitting a whole video
//! into one HTTP response. No asset digest or build-cache entry is needed.
const std = @import("std");
const http = @import("../../lib/http.zig");
const state = @import("state.zig");
const apps_adapter = @import("../apps.zig");

const headers_reserved: u32 = 1024;
const path_bytes_max: u32 = 1024;
pub const Range = struct { start: u64, end: u64 };

pub fn serve(
    request: *http.Request,
    response: *http.Response,
    ctx: *http.Context,
    app: *const state.App,
    root: []const u8,
    path: []const u8,
) !void {
    std.debug.assert(request.header("Range") != null);
    std.debug.assert(ctx.options.response_bytes_max > headers_reserved);

    const file = open_file(app.io, root, path) catch {
        return response.text(.not_found, "Not Found");
    };
    defer file.close(app.io);
    const stat = try file.stat(app.io);

    if (stat.kind != .file) {
        return response.text(.not_found, "Not Found");
    }

    const cap = ctx.options.response_bytes_max - headers_reserved;
    const selected = parse_range(request.header("Range").?, stat.size, cap) orelse {
        const value = try std.fmt.allocPrint(ctx.arena, "bytes */{d}", .{stat.size});

        try response.set_header("Content-Range", value);
        return response.text(.range_not_satisfiable, "Range Not Satisfiable");
    };
    const length: u32 = @intCast(selected.end - selected.start + 1);
    const buffer = try ctx.arena.alloc(u8, length);
    const read = try file.readPositionalAll(app.io, buffer, selected.start);

    if (read != length) {
        return error.UnexpectedEndOfFile;
    }

    const value = try std.fmt.allocPrint(ctx.arena, "bytes {d}-{d}/{d}", .{
        selected.start, selected.end, stat.size,
    });

    try response.set_header("Accept-Ranges", "bytes");
    try response.set_header("Content-Range", value);
    try response.set_header("X-Content-Type-Options", "nosniff");
    try apps_adapter.serve(response, app, .file, .{});
    try response.set_body(.partial_content, http.static.content_type(path), buffer);
}

pub fn parse_range(value: []const u8, size: u64, cap: u32) ?Range {
    std.debug.assert(cap > 0);

    if (size == 0 or !std.mem.startsWith(u8, value, "bytes=")) {
        return null;
    }

    const pair = value["bytes=".len..];
    const dash = std.mem.indexOfScalar(u8, pair, '-') orelse return null;
    var start: u64 = 0;
    var end: u64 = size - 1;

    if (dash == 0) {
        const suffix = std.fmt.parseInt(u64, pair[1..], 10) catch return null;

        if (suffix == 0) {
            return null;
        }

        start = size - @min(size, suffix);
    } else {
        start = std.fmt.parseInt(u64, pair[0..dash], 10) catch return null;

        if (dash + 1 < pair.len) {
            end = @min(end, std.fmt.parseInt(u64, pair[dash + 1 ..], 10) catch return null);
        }
    }

    if (start >= size or end < start) {
        return null;
    }

    end = start + @min(end - start, cap - 1);

    return .{ .start = start, .end = end };
}

/// Open one component at a time, refusing hidden segments and every symlink.
fn open_file(io: std.Io, root: []const u8, path: []const u8) !std.Io.File {
    std.debug.assert(root.len > 0);
    std.debug.assert(path_bytes_max > 0);

    if (path.len == 0 or path.len > path_bytes_max) {
        return error.InvalidPath;
    }

    var directory = try std.Io.Dir.cwd().openDir(io, root, .{});
    defer directory.close(io);
    var parts = std.mem.splitScalar(u8, path, '/');

    while (parts.next()) |part| {
        if (part.len == 0 or part[0] == '.' or std.mem.indexOfAny(u8, part, "\\\x00") != null) {
            return error.InvalidPath;
        }

        if (parts.peek() == null) {
            return directory.openFile(io, part, .{
                .allow_directory = false,
                .follow_symlinks = false,
            });
        }

        const next = try directory.openDir(io, part, .{ .follow_symlinks = false });

        directory.close(io);
        directory = next;
    }

    return error.InvalidPath;
}

test "media ranges clamp to the response budget and reject malformed or empty ranges" {
    const open = parse_range("bytes=0-", 10_000_000, 1024).?;
    try std.testing.expectEqual(@as(u64, 1023), open.end);
    const suffix = parse_range("bytes=-100", 1000, 1024).?;
    try std.testing.expectEqual(@as(u64, 900), suffix.start);
    try std.testing.expectEqual(@as(u64, 999), suffix.end);
    try std.testing.expect(parse_range("bytes=1000-", 1000, 1024) == null);
    try std.testing.expect(parse_range("bytes=10-2", 1000, 1024) == null);
    try std.testing.expect(parse_range("bytes=0-1,4-5", 1000, 1024) == null);
    try std.testing.expect(parse_range("bytes=-0", 1000, 1024) == null);
}
