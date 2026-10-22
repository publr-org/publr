//! `publr plugin check --dir <folder>`: the plugin checks over a plugin's source, each
//! problem with its file and line; exits 1 when there is any. What Publr Cloud's install gate
//! runs, and what `plugin build` runs first for a plugin registering through `define`.
const std = @import("std");
const checks = @import("../../sdk/plugin/checks.zig");
const report = @import("../../lib/report.zig");

pub const files_max: u32 = 512;
const file_bytes_max: u32 = 1 << 20;

pub fn run(init: std.process.Init, args: []const []const u8) !u8 {
    std.debug.assert(args.len < 1 << 16);

    if (args.len != 2 or !std.mem.eql(u8, args[0], "--dir")) {
        report.err("usage: publr plugin check --dir <folder>", .{});
        return 2;
    }

    const found = try problems_in(init, args[1]);

    for (found) |problem| {
        report.err("{s}/{s}:{d}: {s}", .{ args[1], problem.path, problem.line, problem.message });
    }

    return if (found.len == 0) 0 else 1;
}

pub const Found = struct {
    path: []const u8,
    line: u32,
    message: []const u8,
};

/// Every problem under `dir`.
pub fn problems_in(init: std.process.Init, dir: []const u8) ![]const Found {
    std.debug.assert(dir.len > 0);

    const arena = init.arena.allocator();
    var root = try std.Io.Dir.cwd().openDir(init.io, dir, .{
        .iterate = true,
    });
    defer root.close(init.io);

    var walker = try root.walk(arena);
    defer walker.deinit();

    var found: std.ArrayList(Found) = .empty;
    var files: u32 = 0;
    var failures: checks.Failures = .{};

    while (try walker.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) {
            continue;
        }

        files += 1;

        if (files > files_max) {
            return error.TooManyFiles;
        }

        const text = try root.readFileAllocOptions(
            init.io,
            entry.path,
            arena,
            .limited(file_bytes_max),
            .of(u8),
            0,
        );
        var problems: std.ArrayList(checks.Problem) = .empty;
        const path = try arena.dupe(u8, entry.path);

        try checks.check(arena, path, text, &problems);
        try failures.read(arena, path, text);

        for (problems.items) |problem| {
            try found.append(arena, .{
                .path = path,
                .line = problem.line,
                .message = problem.message,
            });
        }
    }

    for (try failures.problems(arena)) |placed| {
        try found.append(arena, .{
            .path = placed.path,
            .line = placed.problem.line,
            .message = placed.problem.message,
        });
    }

    return found.items;
}
