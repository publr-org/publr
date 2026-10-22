const std = @import("std");
const doc_reader = @import("../src/sdk/plugin/doc_reader.zig");
const diagnostic = @import("diagnostic.zig");

const files_max = doc_reader.files_max;

/// Every doc comment in the plugin at `dir`, and the secrets its strings write, as the Zig
/// source of its docs module; the build stops on any plugin check's problem.
pub fn source_of(builder: *std.Build, dir: []const u8) []const u8 {
    std.debug.assert(dir.len > 0);
    std.debug.assert(builder.build_root.path != null);

    const io = builder.graph.io;
    const arena = builder.allocator;
    var root = builder.build_root.handle.openDir(io, dir, .{
        .iterate = true,
    }) catch
        diagnostic.fail("{s}: the plugin's folder is missing", .{dir});
    defer root.close(io);

    var walker = root.walk(arena) catch @panic("OOM");
    defer walker.deinit();

    var files: std.ArrayList(doc_reader.File) = .empty;

    const walk_failed = "{s}: walking the plugin failed";

    while (walker.next(io) catch diagnostic.fail(walk_failed, .{dir})) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) {
            continue;
        }

        if (files.items.len == files_max) {
            diagnostic.fail("{s}: more than {d} Zig files", .{ dir, files_max });
        }

        const text = root.readFileAllocOptions(
            io,
            entry.path,
            arena,
            .limited(doc_reader.file_bytes_max),
            .of(u8),
            0,
        ) catch diagnostic.fail("{s}/{s}: unreadable or over 1 MiB", .{ dir, entry.path });

        files.append(arena, .{
            .path = builder.dupe(entry.path),
            .text = text,
        }) catch @panic("OOM");
    }

    const read = doc_reader.source_of(arena, files.items) catch |err| {
        diagnostic.fail("{s}: doc comments: {s}", .{ dir, @errorName(err) });
    };

    fail_on(dir, read.problems);

    return read.source;
}

/// Stops the build when a check found problems, each printed where it is.
fn fail_on(dir: []const u8, problems: []const doc_reader.Placed) void {
    std.debug.assert(dir.len > 0);
    std.debug.assert(problems.len <= 1 << 16);

    if (problems.len == 0) {
        return;
    }

    for (problems) |found| {
        const where = .{ dir, found.path, found.problem.line, found.problem.message };

        std.log.err("{s}/{s}:{d}: {s}", where);
    }

    diagnostic.fail("{s}: {d} plugin check problem(s)", .{ dir, problems.len });
}
