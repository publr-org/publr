//! Whether a clone's folder holds work of its own: a write to the site made here since it
//! came down (it comes with an empty activity log), or a file of its apps, plugins or
//! `publr.zon` that differs from `.publr/base/`'s. The mark names that work, so a push can
//! say what it sent and the folder can tell later whether anything was made since.
const std = @import("std");
const db = @import("../../lib/db.zig");
const activity = @import("../../store/activity.zig");
const bundle = @import("../bundle.zig");
const clone = @import("../clone.zig");

const walk_entries_max: u32 = 1 << 20;
const Digest = [std.crypto.hash.sha2.Sha256.digest_length]u8;

/// The folder's own work as a short mark, empty for none: its newest write to the site past
/// `since` (its newest when it last matched the site) and its files' digest. Two marks are
/// the same work exactly when they are equal.
pub fn mark(io: std.Io, arena: std.mem.Allocator, folder: []const u8, since: i64) ![]const u8 {
    std.debug.assert(folder.len > 0);
    std.debug.assert(since >= 0);

    const database = try std.fs.path.joinZ(arena, &.{ folder, clone.db_path });
    const base = try std.fs.path.join(arena, &.{ folder, clone.base_dir });
    const written = try latest_write(database, null);
    const own = try digest_of(io, arena, folder);
    const came = try digest_of(io, arena, base);

    if (written <= since and std.mem.eql(u8, &own, &came)) {
        return "";
    }

    const hex = std.fmt.bytesToHex(own[0..8], .lower);
    const text = try std.fmt.allocPrint(arena, "{d}-{s}", .{ written, &hex });

    std.debug.assert(text.len > 0);

    return text;
}

/// The folder's newest write to the site, made by `until_ms` when given.
pub fn latest_write(database: [:0]const u8, until_ms: ?i64) !i64 {
    std.debug.assert(database.len > 0);

    // In this command's own process: never in a server, whose SQLite this would shut down.
    var runtime = try db.Runtime.init(.{});
    defer runtime.deinit();

    var connection = try db.open(&runtime, database);
    defer connection.close();

    const latest = try activity.latest_site_write(&connection, until_ms);

    std.debug.assert(latest >= 0);

    return latest;
}

const Entry = struct {
    path: []const u8,
    hash: Digest,

    fn before(_: void, left: Entry, right: Entry) bool {
        return std.mem.lessThan(u8, left.path, right.path);
    }
};

/// One digest of the folder's apps, plugin sources and `publr.zon`, by name and content, in
/// name order; dot files and build output are not the site's, as a pack leaves them.
fn digest_of(io: std.Io, arena: std.mem.Allocator, root: []const u8) !Digest {
    std.debug.assert(root.len > 0);

    var entries: std.ArrayList(Entry) = .empty;

    for (bundle.project_items) |item| {
        const path = try std.fs.path.join(arena, &.{ root, item });
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };

        if (stat.kind == .directory) {
            try add_tree(io, arena, path, item, &entries);
        } else {
            try entries.append(arena, .{
                .path = item,
                .hash = try hash_file(io, path),
            });
        }
    }

    std.mem.sort(Entry, entries.items, {}, Entry.before);

    var whole: std.crypto.hash.sha2.Sha256 = .init(.{});

    for (entries.items) |entry| {
        whole.update(entry.path);
        whole.update(&.{0});
        whole.update(&entry.hash);
    }

    return whole.finalResult();
}

fn add_tree(
    io: std.Io,
    arena: std.mem.Allocator,
    root: []const u8,
    prefix: []const u8,
    entries: *std.ArrayList(Entry),
) !void {
    std.debug.assert(root.len > 0);
    std.debug.assert(prefix.len > 0);

    var dir = try std.Io.Dir.cwd().openDir(io, root, .{
        .iterate = true,
    });
    defer dir.close(io);

    var walker = try dir.walk(arena);
    defer walker.deinit();

    var seen: u32 = 0;

    while (try walker.next(io)) |entry| : (seen += 1) {
        if (seen == walk_entries_max) {
            return error.TooManyFiles;
        }

        if (entry.basename[0] == '.' or std.mem.eql(u8, entry.basename, "zig-out")) {
            if (entry.kind == .directory) {
                walker.leave(io);
            }

            continue;
        }

        if (entry.kind != .file) {
            continue;
        }

        const name = try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, entry.path });

        std.mem.replaceScalar(u8, name, std.fs.path.sep, '/');
        try entries.append(arena, .{
            .path = name,
            .hash = try hash_file(io, try std.fs.path.join(arena, &.{ root, entry.path })),
        });
    }
}

fn hash_file(io: std.Io, path: []const u8) !Digest {
    std.debug.assert(path.len > 0);

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var through: [16 << 10]u8 = undefined;
    var chunk: [64 << 10]u8 = undefined;
    var reader = file.reader(io, &through);
    var hasher: std.crypto.hash.sha2.Sha256 = .init(.{});

    while (true) {
        const count = try reader.interface.readSliceShort(&chunk);

        if (count == 0) {
            break;
        }

        hasher.update(chunk[0..count]);
    }

    return hasher.finalResult();
}

test "a folder's files: the same in any order, another for any change" {
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const io = std.testing.io;
    const files = [_][2][]const u8{
        .{ "one/publr.zon", ".{}" },
        .{ "one/apps/www/index.publr", "<h1>Hi</h1>" },
        .{ "one/apps/www/about.publr", "<p>About</p>" },
        .{ "one/apps/www/.DS_Store", "x" },
        .{ "two/apps/www/about.publr", "<p>About</p>" },
        .{ "two/apps/www/index.publr", "<h1>Hi</h1>" },
        .{ "two/publr.zon", ".{}" },
    };

    for (files) |file| {
        try scratch.dir.createDirPath(io, std.fs.path.dirname(file[0]).?);
        try scratch.dir.writeFile(io, .{
            .sub_path = file[0],
            .data = file[1],
        });
    }

    const root = try scratch.dir.realPathFileAlloc(io, ".", arena);
    const one = try std.fs.path.join(arena, &.{ root, "one" });
    const two = try std.fs.path.join(arena, &.{ root, "two" });

    try std.testing.expectEqualSlices(u8, &try digest_of(io, arena, one), &try digest_of(
        io,
        arena,
        two,
    ));
    try scratch.dir.writeFile(io, .{
        .sub_path = "two/apps/www/index.publr",
        .data = "<h1>Hello</h1>",
    });
    try std.testing.expect(!std.mem.eql(u8, &try digest_of(io, arena, one), &try digest_of(
        io,
        arena,
        two,
    )));
}
