//! Puts in every struct's missing last comma (`tidy/literals.zig`) in the Zig files under
//! the folders given, then leaves the layout to `zig fmt`. `.zig-cache` and `zig-out` are
//! skipped. Prints each file it changed.
const std = @import("std");
const literals = @import("tidy/literals.zig");

const file_bytes_max: u32 = 8 << 20;

pub fn main(init: std.process.Init) !u8 {
    var arguments = try init.minimal.args.iterateAllocator(init.arena.allocator());
    var changed: u32 = 0;

    std.debug.assert(file_bytes_max > 0);

    _ = arguments.next();

    while (arguments.next()) |root| {
        const cwd = std.Io.Dir.cwd();
        const stat = try cwd.statFile(init.io, root, .{});

        if (stat.kind == .file) {
            changed += try fix(init, cwd, root, root);
            continue;
        }

        var dir = try cwd.openDir(init.io, root, .{
            .iterate = true,
        });
        defer dir.close(init.io);

        var walker = try dir.walk(init.gpa);
        defer walker.deinit();

        while (try walker.next(init.io)) |entry| {
            const skipped = std.mem.indexOf(u8, entry.path, ".zig-cache") != null or
                std.mem.indexOf(u8, entry.path, "zig-out") != null;

            if (entry.kind != .file or skipped or !std.mem.endsWith(u8, entry.basename, ".zig")) {
                continue;
            }

            changed += try fix(init, entry.dir, entry.basename, entry.path);
        }
    }

    std.debug.print("fix-literals: {d} file(s) changed\n", .{changed});

    return 0;
}

fn fix(init: std.process.Init, dir: std.Io.Dir, basename: []const u8, path: []const u8) !u32 {
    std.debug.assert(basename.len > 0);

    const gpa = init.gpa;
    const limit: std.Io.Limit = .limited(file_bytes_max);
    const text = try dir.readFileAllocOptions(init.io, basename, gpa, limit, .of(u8), 0);
    defer gpa.free(text);

    const missing = try literals.find(gpa, text);
    defer gpa.free(missing);

    if (missing.len == 0) {
        return 0;
    }

    const repaired = try literals.fixed(gpa, text, missing);
    defer gpa.free(repaired);

    try dir.writeFile(init.io, .{
        .sub_path = basename,
        .data = repaired,
    });
    std.debug.print("{s}: {d}\n", .{ path, missing.len });

    return 1;
}
