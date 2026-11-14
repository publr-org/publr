//! A pulled site put in place in its folder: the database, apps, plugins and `publr.zon`
//! replaced by the site's, the new and changed media files added and the ones the site no
//! longer has removed. What was replaced is kept once in `.publr/previous/`. This machine's
//! rows (who is signed in here, its devices, whom it trusts to sign people in) stay.
const std = @import("std");
const db = @import("../../lib/db.zig");
const bundle = @import("../bundle.zig");
const clone = @import("../clone.zig");
const writing = @import("folder.zig");
const site_side = @import("site.zig");

const incoming_dir = ".publr/incoming";
const previous_dir = ".publr/previous";
const media_dir = "data/media";
const installed_dir = "data/plugins";
const walk_entries_max: u32 = 1 << 24;

/// This machine's rows carried into the pulled database, for the accounts it still has.
const kept_rows = [_][:0]const u8{
    "INSERT OR REPLACE INTO settings SELECT * FROM here.settings " ++
        "WHERE key LIKE 'sign\\_on.%' ESCAPE '\\'",
    "INSERT OR IGNORE INTO sessions SELECT * FROM here.sessions " ++
        "WHERE user_id IN (SELECT id FROM users)",
    "INSERT OR IGNORE INTO devices SELECT * FROM here.devices " ++
        "WHERE user_id IN (SELECT id FROM users)",
};

/// The media files `folder` holds, by key and the hash its database gives them: a pull
/// leaves out those the site holds the same. A placeholder counts, so it stays one.
pub fn held(io: std.Io, arena: std.mem.Allocator, folder: []const u8) ![]const site_side.Held {
    std.debug.assert(folder.len > 0);

    const database = try std.fs.path.joinZ(arena, &.{ folder, clone.db_path });
    var runtime = try db.Runtime.init(.{});
    defer runtime.deinit();

    var connection = try db.open(&runtime, database);
    defer connection.close();

    var select = try connection.prepare("SELECT storage_key, hash FROM media");
    defer select.finalize();

    const Row = struct {
        storage_key: []const u8,
        hash: []const u8,
    };
    var files: std.ArrayList(site_side.Held) = .empty;
    const cwd = std.Io.Dir.cwd();

    while (try select.step()) {
        const row = try select.read(Row, arena);
        const path = try std.fs.path.join(arena, &.{ folder, media_dir, row.storage_key });
        const there = if (cwd.access(io, path, .{})) |_| true else |_| false;

        if (there) {
            try files.append(arena, .{
                .key = row.storage_key,
                .hash = row.hash,
            });
        }
    }

    return files.items;
}

/// The bundle at `download` put in place in `folder`.
pub fn apply(
    init: std.process.Init,
    arena: std.mem.Allocator,
    folder: []const u8,
    download: []const u8,
) !void {
    std.debug.assert(folder.len > 0);
    std.debug.assert(download.len > 0);

    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const incoming = try std.fs.path.join(arena, &.{ folder, incoming_dir });
    const previous = try std.fs.path.join(arena, &.{ folder, previous_dir });

    try cwd.deleteTree(io, incoming);
    defer cwd.deleteTree(io, incoming) catch |err| {
        std.log.warn("removing {s}: {t}", .{ incoming, err });
    };

    _ = try writing.unpack_into(init, arena, incoming, download, .{});
    try keep_local_rows(arena, folder, incoming);
    try cwd.deleteTree(io, previous);
    try cwd.createDirPath(io, try std.fs.path.join(arena, &.{ previous, "data" }));

    const database = clone.db_path;
    const replaced = [_][]const u8{
        database,
        database ++ "-wal",
        database ++ "-shm",
        installed_dir,
    } ++ bundle.project_items;

    for (replaced) |item| {
        try move(io, arena, folder, item, previous, item);
        try move(io, arena, incoming, item, folder, item);
    }

    try add_media(io, arena, incoming, folder);
    try remove_gone_media(io, arena, folder);
}

/// `from/<name>` moved to `to/<as>` when it is there.
fn move(
    io: std.Io,
    arena: std.mem.Allocator,
    from: []const u8,
    name: []const u8,
    to: []const u8,
    as: []const u8,
) !void {
    std.debug.assert(name.len > 0);
    std.debug.assert(as.len > 0);

    const cwd = std.Io.Dir.cwd();
    const source = try std.fs.path.join(arena, &.{ from, name });
    const target = try std.fs.path.join(arena, &.{ to, as });

    cwd.access(io, source, .{}) catch return;
    try cwd.createDirPath(io, std.fs.path.dirname(target).?);
    try cwd.rename(source, cwd, target, io);
}

fn keep_local_rows(arena: std.mem.Allocator, folder: []const u8, incoming: []const u8) !void {
    std.debug.assert(kept_rows.len > 0);

    const own = try std.fs.path.join(arena, &.{ folder, clone.db_path });
    const pulled = try std.fs.path.joinZ(arena, &.{ incoming, clone.db_path });
    var runtime = try db.Runtime.init(.{});
    defer runtime.deinit();

    var connection = try db.open(&runtime, pulled);
    defer connection.close();

    var attach = try connection.prepare("ATTACH DATABASE ?1 AS here");
    defer attach.finalize();

    try attach.bind_text(1, own);

    // SQLite counts ATTACH as a read-only statement, which `exec` refuses.
    const row = try attach.step();

    std.debug.assert(!row);

    inline for (kept_rows) |statement| {
        try connection.exec(statement);
    }
}

/// Every media file the pull brought, moved into the folder's media.
fn add_media(io: std.Io, arena: std.mem.Allocator, incoming: []const u8, folder: []const u8) !void {
    std.debug.assert(incoming.len > 0);

    const root = try std.fs.path.join(arena, &.{ incoming, media_dir });
    var dir = std.Io.Dir.cwd().openDir(io, root, .{
        .iterate = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var walker = try dir.walk(arena);
    defer walker.deinit();

    var files: std.ArrayList([]const u8) = .empty;
    var seen: u32 = 0;

    while (try walker.next(io)) |entry| : (seen += 1) {
        if (seen == walk_entries_max) {
            return error.TooManyFiles;
        }

        if (entry.kind == .file) {
            try files.append(arena, try arena.dupe(u8, entry.path));
        }
    }

    const media = try std.fs.path.join(arena, &.{ folder, media_dir });

    for (files.items) |path| {
        try move(io, arena, root, path, media, path);
    }
}

/// The folder's media files whose key the pulled database no longer has, removed; the
/// resized copies (dot folders) are left to the server, which makes them again.
fn remove_gone_media(io: std.Io, arena: std.mem.Allocator, folder: []const u8) !void {
    std.debug.assert(folder.len > 0);

    const keys = try keys_of(arena, folder);
    const root = try std.fs.path.join(arena, &.{ folder, media_dir });
    var dir = std.Io.Dir.cwd().openDir(io, root, .{
        .iterate = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var walker = try dir.walk(arena);
    defer walker.deinit();

    var gone: std.ArrayList([]const u8) = .empty;
    var seen: u32 = 0;

    while (try walker.next(io)) |entry| : (seen += 1) {
        if (seen == walk_entries_max) {
            return error.TooManyFiles;
        }

        if (entry.basename[0] == '.') {
            if (entry.kind == .directory) {
                walker.leave(io);
            }

            continue;
        }

        const key = try arena.dupe(u8, entry.path);

        std.mem.replaceScalar(u8, key, std.fs.path.sep, '/');

        if (entry.kind == .file and !keys.contains(key)) {
            try gone.append(arena, key);
        }
    }

    for (gone.items) |key| {
        try dir.deleteFile(io, key);
    }
}

fn keys_of(arena: std.mem.Allocator, folder: []const u8) !std.StringHashMapUnmanaged(void) {
    std.debug.assert(folder.len > 0);

    const database = try std.fs.path.joinZ(arena, &.{ folder, clone.db_path });
    var runtime = try db.Runtime.init(.{});
    defer runtime.deinit();

    var connection = try db.open(&runtime, database);
    defer connection.close();

    var select = try connection.prepare("SELECT storage_key FROM media");
    defer select.finalize();

    const Row = struct {
        storage_key: []const u8,
    };
    var keys: std.StringHashMapUnmanaged(void) = .empty;

    while (try select.step()) {
        const row = try select.read(Row, arena);

        try keys.put(arena, row.storage_key, {});
    }

    return keys;
}
