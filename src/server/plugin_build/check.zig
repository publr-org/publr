//! `publr plugin check --dir <folder>`: the plugin checks over a plugin's source, each
//! problem with its file and line; exits 1 for an error, never for a warning. What the
//! install gate runs over the source a module carries, and what `plugin build` runs first,
//! through the same reading of the plugin.
const std = @import("std");
const doc_reader = @import("../../sdk/plugin/doc_reader.zig");
const report = @import("../../lib/report.zig");
const groq = @import("../../lib/groq.zig");

pub fn run(init: std.process.Init, args: []const []const u8) !u8 {
    std.debug.assert(args.len < 1 << 16);

    if (args.len != 2 or !std.mem.eql(u8, args[0], "--dir")) {
        report.err("usage: publr plugin check --dir <folder>", .{});
        return 2;
    }

    const arena = init.arena.allocator();
    const read = try doc_reader.source_of(arena, try files_in(init, args[1]));
    const problems = try problems_of(arena, read);

    reported(args[1], problems);

    return if (doc_reader.failing(problems)) 1 else 0;
}

/// What the checks found over the source, and each prepared query that does not read.
pub fn problems_of(arena: std.mem.Allocator, read: doc_reader.Source) ![]const doc_reader.Placed {
    std.debug.assert(read.source.len > 0);

    var problems: std.ArrayList(doc_reader.Placed) = .empty;

    try problems.appendSlice(arena, read.problems);

    for (read.queries) |query| {
        const problem = try groq.problem_of(arena, query.text) orelse continue;

        try problems.append(arena, .{
            .path = query.path,
            .problem = .{
                .line = query.line,
                .message = try std.fmt.allocPrint(arena, "the query does not read: {s}", .{
                    problem,
                }),
            },
        });
    }

    return problems.items;
}

/// Each problem printed where it is; a warning says so and stops nothing.
pub fn reported(dir: []const u8, problems: []const doc_reader.Placed) void {
    std.debug.assert(dir.len > 0);

    for (problems) |placed| {
        const where = .{ dir, placed.path, placed.problem.line, placed.problem.message };

        if (placed.problem.warning) {
            report.warn_reason("", "{s}/{s}:{d}: warning: {s}", where);
        } else {
            report.err("{s}/{s}:{d}: {s}", where);
        }
    }
}

/// Every Zig and GROQ file under `dir`, read.
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
        if (entry.kind != .file or !doc_reader.read_file(entry.path)) {
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

test "plugin check: a prepared query that does not read, where it is" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const files = [_]doc_reader.File{
        .{
            .path = "main.zig",
            .text =
            \\//! Shelf
            \\const counted = publr.query.prepare(@embedFile("queries/bad.groq"), .{});
            ,
        },
        .{
            .path = "queries/bad.groq",
            .text = "*[_type == ",
        },
    };
    const problems = try problems_of(arena, try doc_reader.source_of(arena, &files));

    try std.testing.expectEqual(@as(usize, 1), problems.len);
    try std.testing.expectEqualStrings("main.zig", problems[0].path);
    try std.testing.expectEqual(@as(u32, 2), problems[0].problem.line);
    const message = problems[0].problem.message;

    try std.testing.expect(std.mem.startsWith(u8, message, "the query does not read: "));
}
