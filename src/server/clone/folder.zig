//! The clone written to its folder: the site, `.publr/base/` the same site as it came (its
//! database only, the merge base later), and `.publr/clone.json`, the link back.
const std = @import("std");
const backup = @import("../gate/backup.zig");
const bundle = @import("../bundle.zig");
const clone = @import("../clone.zig");
const linking = @import("link.zig");

const base_dir = clone.base_dir;
const db_path = clone.db_path;

/// `folder` the site, `.publr/base/` the same site as it was (database and structure, no
/// media), and the link back.
pub fn write_folder(
    init: std.process.Init,
    arena: std.mem.Allocator,
    folder: []const u8,
    download: []const u8,
    address: []const u8,
    written: *std.atomic.Value(u64),
) !void {
    std.debug.assert(folder.len > 0);

    const base = try std.fs.path.join(arena, &.{ folder, base_dir });
    const manifest = try unpack_into(init, arena, folder, download, .{
        .written = written,
    });

    _ = try unpack_into(init, arena, base, download, .{
        .media = false,
    });
    try keep_only_database(init.io, arena, base);

    var dir = try std.Io.Dir.cwd().openDir(init.io, folder, .{});
    defer dir.close(init.io);

    try linking.write(init.io, arena, dir, .{
        .site = address,
        .branch = try linking.new_branch(init.io, arena),
        .pulled = manifest.latest_change,
    });
}

pub fn unpack_into(
    init: std.process.Init,
    arena: std.mem.Allocator,
    folder: []const u8,
    download: []const u8,
    options: bundle.UnpackOptions,
) !bundle.Manifest {
    std.debug.assert(folder.len > 0);

    const database = try std.fs.path.join(arena, &.{ folder, db_path });

    try std.Io.Dir.cwd().createDirPath(init.io, std.fs.path.dirname(database).?);

    const site = try backup.Site.of(init.io, arena, database, folder);

    return bundle.unpack(site, arena, download, options);
}

/// Everything in the base's data folder but its database: media stays once, in the site.
pub fn keep_only_database(io: std.Io, arena: std.mem.Allocator, base: []const u8) !void {
    std.debug.assert(base.len > 0);

    const data = try std.fs.path.join(arena, &.{ base, "data" });
    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(io, data, .{
        .iterate = true,
    });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var iterator = dir.iterate();

    while (try iterator.next(io)) |entry| {
        if (!std.mem.eql(u8, entry.name, std.fs.path.basename(db_path))) {
            try names.append(arena, try arena.dupe(u8, entry.name));
        }
    }

    for (names.items) |name| {
        try dir.deleteTree(io, name);
    }
}
