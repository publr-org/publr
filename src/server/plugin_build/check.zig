//! `publr plugin check --dir <folder>`: the plugin checks over a plugin's source, each
//! problem with its file and line; exits 1 when there is any. What Publr Cloud's install gate
//! runs, and what `plugin build` runs first, through the same reading of the plugin.
const std = @import("std");
const doc_reader = @import("../../sdk/plugin/doc_reader.zig");
const report = @import("../../lib/report.zig");

pub fn run(init: std.process.Init, args: []const []const u8) !u8 {
    std.debug.assert(args.len < 1 << 16);

    if (args.len != 2 or !std.mem.eql(u8, args[0], "--dir")) {
        report.err("usage: publr plugin check --dir <folder>", .{});
        return 2;
    }

    const arena = init.arena.allocator();
    const read = try doc_reader.source_of(arena, try files_in(init, args[1]));

    reported(args[1], read.problems);

    return if (read.problems.len == 0) 0 else 1;
}

/// Each problem printed where it is.
pub fn reported(dir: []const u8, problems: []const doc_reader.Placed) void {
    std.debug.assert(dir.len > 0);

    for (problems) |placed| {
        const where = .{ dir, placed.path, placed.problem.line, placed.problem.message };

        report.err("{s}/{s}:{d}: {s}", where);
    }
}

/// Every Zig file under `dir`, read.
pub fn files_in(init: std.process.Init, dir: []const u8) ![]const doc_reader.File {
    std.debug.assert(dir.len > 0);

    const arena = init.arena.allocator();
    var root = try std.Io.Dir.cwd().openDir(init.io, dir, .{
        .iterate = true,
    });
    defer root.close(init.io);

    var walker = try root.walk(arena);
    defer walker.deinit();

    var files: std.ArrayList(doc_reader.File) = .empty;

    while (try walker.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) {
            continue;
        }

        if (files.items.len == doc_reader.files_max) {
            return error.TooManyFiles;
        }

        try files.append(arena, .{
            .path = try arena.dupe(u8, entry.path),
            .text = try root.readFileAllocOptions(
                init.io,
                entry.path,
                arena,
                .limited(doc_reader.file_bytes_max),
                .of(u8),
                0,
            ),
        });
    }

    return files.items;
}
