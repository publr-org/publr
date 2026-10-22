const std = @import("std");
const doc_reader = @import("../src/sdk/plugin/doc_reader.zig");
const written_secrets = @import("../src/sdk/plugin/written_secrets.zig");
const checks = @import("../src/sdk/plugin/checks.zig");
const diagnostic = @import("diagnostic.zig");

pub const files_max: u32 = 512;

const Found = struct {
    path: []const u8,
    problem: checks.Problem,
};

const file_bytes_max: u32 = 1 << 20;

/// Every doc comment in the plugin at `dir`, and the secrets its strings write, as the Zig
/// source of its docs module.
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

    var entries: std.ArrayList(doc_reader.Entry) = .empty;
    var written: std.ArrayList([]const u8) = .empty;
    var problems: std.ArrayList(Found) = .empty;
    var failures: checks.Failures = .{};
    var files: u32 = 0;

    const walk_failed = "{s}: walking the plugin failed";

    while (walker.next(io) catch diagnostic.fail(walk_failed, .{dir})) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) {
            continue;
        }

        files += 1;

        if (files > files_max) {
            diagnostic.fail("{s}: more than {d} Zig files", .{ dir, files_max });
        }

        const text = root.readFileAllocOptions(
            io,
            entry.path,
            arena,
            .limited(file_bytes_max),
            .of(u8),
            0,
        ) catch diagnostic.fail("{s}/{s}: unreadable or over 1 MiB", .{ dir, entry.path });
        const key = doc_reader.file_key(arena, entry.path) catch @panic("OOM");

        doc_reader.read(arena, key, text, &entries) catch |err| {
            diagnostic.fail("{s}/{s}: doc comments: {s}", .{ dir, entry.path, @errorName(err) });
        };
        written_secrets.read(arena, text, &written) catch @panic("OOM");

        var found: std.ArrayList(checks.Problem) = .empty;
        const path = builder.dupe(entry.path);

        checks.check(arena, entry.path, text, &found) catch @panic("OOM");
        failures.read(arena, path, text) catch @panic("OOM");

        for (found.items) |problem| {
            problems.append(arena, .{
                .path = path,
                .problem = problem,
            }) catch @panic("OOM");
        }
    }

    for (failures.problems(arena) catch @panic("OOM")) |placed| {
        problems.append(arena, .{
            .path = placed.path,
            .problem = placed.problem,
        }) catch @panic("OOM");
    }

    fail_on(dir, problems.items);

    const words = doc_reader.generated(arena, entries.items) catch @panic("OOM");
    const secrets = written_secrets.source(arena, written.items) catch @panic("OOM");

    return std.mem.concat(arena, u8, &.{ words, secrets }) catch @panic("OOM");
}

/// Stops the build when a check found problems, each printed where it is.
fn fail_on(dir: []const u8, problems: []const Found) void {
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
