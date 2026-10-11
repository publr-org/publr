//! What a release shipped never changes: its fixture is evidence of what it wrote, and its
//! migration is what every later release runs. Each is compared with the file in its tag.

const std = @import("std");

const output_bytes_max: u32 = 256 << 20;
const migrations_dir = "src/lib/db/migrations";

/// Whether every released fixture and migration is the file its tag holds. A file with no
/// tag here (a release being made, a clone without tags) is named, not failed.
pub fn expect_unchanged(init: std.process.Init, fixtures: []const u8, releasing: bool) !bool {
    std.debug.assert(fixtures.len > 0);
    std.debug.assert(output_bytes_max > 0);

    const arena = init.arena.allocator();
    const fixtures_real = try std.Io.Dir.cwd().realPathFileAlloc(init.io, fixtures, arena);
    const repo = std.fs.path.dirname(std.fs.path.dirname(fixtures_real) orelse ".") orelse ".";
    var same = true;

    for (try names_in(init, fixtures_real, ".tar.gz")) |name| {
        const release = name[0 .. name.len - ".tar.gz".len];
        const lived = std.mem.eql(u8, release, "lived");

        if (lived and releasing) {
            continue;
        }

        const tag = if (lived)
            try latest_tag(init, repo) orelse continue
        else
            try std.fmt.allocPrint(arena, "v{s}", .{release});
        const path = try std.fmt.allocPrint(arena, "fixtures/upgrade/{s}", .{name});

        same = try compare(init, repo, tag, path) and same;
    }

    const migrations = try std.fs.path.join(arena, &.{ repo, migrations_dir });

    for (try names_in(init, migrations, ".zig")) |name| {
        const release = name[0 .. name.len - ".zig".len];

        if (std.SemanticVersion.parse(release)) |_| {
            const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ migrations_dir, name });
            const tag = try std.fmt.allocPrint(arena, "v{s}", .{release});

            same = try compare(init, repo, tag, path) and same;
        } else |_| {}
    }

    return same;
}

/// Whether `path` is what `tag` holds; true when the tag is not here, or does not hold it.
fn compare(init: std.process.Init, repo: []const u8, tag: []const u8, path: []const u8) !bool {
    std.debug.assert(tag.len > 0);
    std.debug.assert(path.len > 0);

    const arena = init.arena.allocator();
    const spec = try std.fmt.allocPrint(arena, "{s}:{s}", .{ tag, path });
    const shipped = try std.process.run(arena, init.io, .{
        .argv = &.{ "git", "-C", repo, "cat-file", "blob", spec },
        .stdout_limit = .limited(output_bytes_max),
        .stderr_limit = .limited(64 << 10),
    });

    if (shipped.term != .exited or shipped.term.exited != 0) {
        std.debug.print("upgrade: {s} has no {s} here; not compared\n", .{ tag, path });
        return true;
    }

    const local = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        try std.fs.path.join(arena, &.{ repo, path }),
        arena,
        .limited(output_bytes_max),
    );

    if (!std.mem.eql(u8, local, shipped.stdout)) {
        std.debug.print("upgrade: {s} differs from the one {s} shipped. A released fixture " ++
            "or migration never changes: put it back (`git checkout {s} -- {s}`) and fix " ++
            "forward in the next migration\n", .{ path, tag, tag, path });
        return false;
    }

    return true;
}

pub fn latest_tag(init: std.process.Init, repo: []const u8) !?[]const u8 {
    std.debug.assert(repo.len > 0);

    const found = try std.process.run(init.arena.allocator(), init.io, .{
        .argv = &.{ "git", "-C", repo, "describe", "--tags", "--abbrev=0", "--match", "v*" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });

    if (found.term != .exited or found.term.exited != 0) {
        return null;
    }

    return std.mem.trim(u8, found.stdout, " \n");
}

fn names_in(init: std.process.Init, dir_path: []const u8, suffix: []const u8) ![]const []const u8 {
    std.debug.assert(suffix.len > 0);

    const arena = init.arena.allocator();
    const options: std.Io.Dir.OpenOptions = .{
        .iterate = true,
    };
    var dir = std.Io.Dir.cwd().openDir(init.io, dir_path, options) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close(init.io);

    var names: std.ArrayList([]const u8) = .empty;
    var iterator = dir.iterate();

    while (try iterator.next(init.io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, suffix)) {
            try names.append(arena, try arena.dupe(u8, entry.name));
        }
    }

    return names.items;
}
