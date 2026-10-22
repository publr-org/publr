const std = @import("std");
const db = @import("../../lib/db.zig");
const settings = @import("../../store/settings.zig");
const backup = @import("../gate/backup.zig");
const gate = @import("../gate.zig");
const bundle = @import("../bundle.zig");

/// Folders under the data folder that are this machine's: backups, agents' logs and
/// screens, plugin builds, and installs that never finished.
const data_left_out = [_][]const u8{ "backups", "agents", "builds", "plugins/incoming" };
/// Rows that belong to this machine, deleted from the snapshot: who is signed in, the
/// devices and the sign-on it trusts, live agents and the build index (the built pages stay
/// behind, so the next host builds them all). The activity and error logs are append-only
/// and go with the site.
const local_rows = [_][:0]const u8{
    "DELETE FROM sessions",
    "DELETE FROM devices",
    "DELETE FROM device_requests",
    "DELETE FROM sign_on_tokens",
    "DELETE FROM settings WHERE key LIKE 'sign\\_on.%' ESCAPE '\\'",
    "DELETE FROM ai_activity",
    "DELETE FROM ai_browsers",
    "DELETE FROM deps_edges",
    "DELETE FROM deps_artifacts",
    "DELETE FROM deps_pending",
    "DELETE FROM deps_meta",
};
const copy_buffer_bytes: u32 = 64 << 10;

const Compressor = struct {
    window: [std.compress.flate.max_window_len]u8,
    compress: std.compress.flate.Compress,
};

/// The site written to `out_path` as a bundle; `bundle.zig` says what it holds.
pub fn pack(
    site: backup.Site,
    arena: std.mem.Allocator,
    out_path: []const u8,
    name: []const u8,
) !bundle.Packed {
    std.debug.assert(out_path.len > 0);
    std.debug.assert(name.len > 0);

    const io = site.io;
    const cwd = std.Io.Dir.cwd();
    const snapshot = try std.fmt.allocPrintSentinel(arena, "{s}.snapshot", .{out_path}, 0);

    try remove_if_there(io, snapshot);
    defer remove_if_there(io, snapshot) catch |err| {
        std.log.warn("removing {s}: {t}", .{ snapshot, err });
    };

    const manifest: bundle.Manifest = .{
        .release = try take_snapshot(site, arena, snapshot),
        .name = name,
        .made_at_ms = @import("../../sdk.zig").context.wall_clock_ms(io),
        .database = site.database,
    };
    var file = try cwd.createFile(io, out_path, .{});
    defer file.close(io);
    errdefer remove_if_there(io, out_path) catch |err| {
        std.log.warn("removing the unfinished {s}: {t}", .{ out_path, err });
    };

    var file_buffer: [copy_buffer_bytes]u8 = undefined;
    var file_writer = file.writer(io, &file_buffer);
    const compressor = try std.heap.page_allocator.create(Compressor);
    defer std.heap.page_allocator.destroy(compressor);

    compressor.compress = try .init(&file_writer.interface, &compressor.window, .gzip, .default);

    var archive: Archive = .{
        .site = site,
        .arena = arena,
        .tar = .{
            .underlying_writer = &compressor.compress.writer,
        },
    };

    try archive.add_all(manifest, snapshot);
    try compressor.compress.finish();
    try file_writer.interface.flush();

    return .{
        .manifest = manifest,
        .files = archive.files,
        .bytes = archive.bytes,
    };
}

fn remove_if_there(io: std.Io, path: []const u8) !void {
    std.debug.assert(path.len > 0);
    std.debug.assert(!std.mem.endsWith(u8, path, "/"));

    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

const Tree = enum { data, project };

const Archive = struct {
    site: backup.Site,
    arena: std.mem.Allocator,
    tar: std.tar.Writer,
    files: u32 = 0,
    bytes: u64 = 0,

    fn add_all(archive: *Archive, manifest: bundle.Manifest, snapshot: []const u8) !void {
        std.debug.assert(snapshot.len > 0);
        std.debug.assert(archive.files == 0);

        const site = archive.site;
        const about = try std.json.Stringify.valueAlloc(archive.arena, manifest, .{
            .whitespace = .indent_2,
        });

        try archive.tar.writeFileBytes(bundle.manifest_name, about, .{});
        try archive.add_file(snapshot, try join(archive.arena, "data", site.database));
        try archive.add_tree(site.data_dir, "data", .data);

        for (bundle.project_items) |item| {
            try archive.add_project_item(item);
        }

        try archive.tar.finishPedantically();
    }

    fn add_file(archive: *Archive, path: []const u8, name: []const u8) !void {
        std.debug.assert(path.len > 0);
        std.debug.assert(name.len > 0);

        const io = archive.site.io;
        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        var buffer: [copy_buffer_bytes]u8 = undefined;
        var reader = file.reader(io, &buffer);
        const size = try reader.getSize();

        try archive.tar.writeFileStream(name, size, &reader.interface, .{});
        archive.files += 1;
        archive.bytes += size;
    }

    /// Every file under `root`, named `<prefix>/<its path>`, but what stays behind.
    fn add_tree(archive: *Archive, root: []const u8, prefix: []const u8, tree: Tree) !void {
        std.debug.assert(std.fs.path.isAbsolute(root));
        std.debug.assert(prefix.len > 0);

        const io = archive.site.io;
        var dir = try std.Io.Dir.cwd().openDir(io, root, .{
            .iterate = true,
        });
        defer dir.close(io);
        var walker = try dir.walk(archive.arena);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            if (left_out(archive.site, entry.path, entry.basename, tree)) {
                if (entry.kind == .directory) {
                    walker.leave(io);
                }

                continue;
            }

            if (entry.kind != .file) {
                continue;
            }

            const relative = try slashed(archive.arena, entry.path);
            const path = try std.fs.path.join(archive.arena, &.{ root, entry.path });

            try archive.add_file(path, try join(archive.arena, prefix, relative));
        }
    }

    /// `site/<item>` when the project folder has it.
    fn add_project_item(archive: *Archive, item: []const u8) !void {
        std.debug.assert(item.len > 0);
        std.debug.assert(archive.files > 0);

        const site = archive.site;
        const path = try std.fs.path.join(archive.arena, &.{ site.project_dir, item });
        const stat = std.Io.Dir.cwd().statFile(site.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        const name = try join(archive.arena, "site", item);

        if (stat.kind == .directory) {
            return archive.add_tree(path, name, .project);
        }

        try archive.add_file(path, name);
    }
};

/// What stays behind: dot files and folders (caches, unfinished uploads, `.DS_Store`),
/// build output, and in the data folder the database itself (the snapshot stands for it,
/// its journal and serve marker too) and this machine's folders. In a folder that is
/// both (a Cloud project), the project's items go under `site/` instead.
pub fn left_out(site: backup.Site, path: []const u8, basename: []const u8, tree: Tree) bool {
    std.debug.assert(path.len > 0);
    std.debug.assert(basename.len > 0);

    if (basename[0] == '.' or std.mem.eql(u8, basename, "zig-out")) {
        return true;
    }

    if (tree == .project) {
        return false;
    }

    const top_level = std.mem.indexOfScalar(u8, path, std.fs.path.sep) == null;

    if (top_level and std.mem.startsWith(u8, path, site.database)) {
        return true;
    }

    for (data_left_out) |kept| {
        if (same_path(path, kept)) {
            return true;
        }
    }

    if (!std.mem.eql(u8, site.project_dir, site.data_dir)) {
        return false;
    }

    for (bundle.project_items) |item| {
        if (std.mem.eql(u8, path, item)) {
            return true;
        }
    }

    return false;
}

/// The database copied to `path`, consistent while a server writes to the original
/// (`VACUUM INTO`), with this machine's rows taken out and the pages that held them
/// rewritten; the release that last opened it, empty for none.
fn take_snapshot(site: backup.Site, arena: std.mem.Allocator, path: [:0]const u8) ![]const u8 {
    std.debug.assert(path.len > 0);
    std.debug.assert(local_rows.len > 0);

    var runtime = try db.Runtime.init(.{});
    defer runtime.deinit();

    try copy_database(site, arena, &runtime, path);

    var copy = try db.open(&runtime, path);
    defer copy.close();

    inline for (local_rows) |statement| {
        if (try db.schema.has_table(&copy, comptime table_of(statement))) {
            try copy.exec(statement);
        }
    }

    try copy.exec("PRAGMA journal_mode = DELETE");

    var vacuum = try copy.prepare("VACUUM");
    defer vacuum.finalize();
    // SQLite counts VACUUM as a read-only statement, which `exec` refuses.
    const row = try vacuum.step();

    std.debug.assert(!row);

    if (!try db.schema.has_table(&copy, "settings")) {
        return "";
    }

    return try settings.get(&copy, arena, gate.release_key) orelse "";
}

fn copy_database(
    site: backup.Site,
    arena: std.mem.Allocator,
    runtime: *db.Runtime,
    path: [:0]const u8,
) !void {
    std.debug.assert(path.len > 0);
    std.debug.assert(site.database.len > 0);

    const source = try std.fs.path.joinZ(arena, &.{ site.data_dir, site.database });
    var connection = try db.open(runtime, source);
    defer connection.close();

    try db.copy_to(&connection, path);
}

/// `DELETE FROM <table> ...`: the table.
fn table_of(comptime statement: []const u8) []const u8 {
    const prefix = "DELETE FROM ";

    comptime std.debug.assert(std.mem.startsWith(u8, statement, prefix));

    const rest = statement[prefix.len..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;

    comptime std.debug.assert(end > 0);

    return rest[0..end];
}

fn same_path(path: []const u8, kept: []const u8) bool {
    std.debug.assert(kept.len > 0);
    std.debug.assert(path.len > 0);

    if (path.len != kept.len) {
        return false;
    }

    for (path, kept) |own, wanted| {
        const same = own == wanted or (own == std.fs.path.sep and wanted == '/');

        if (!same) {
            return false;
        }
    }

    return true;
}

fn slashed(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    std.debug.assert(path.len > 0);
    std.debug.assert(!std.fs.path.isAbsolute(path));

    const copy = try arena.dupe(u8, path);

    std.mem.replaceScalar(u8, copy, std.fs.path.sep, '/');

    return copy;
}

fn join(arena: std.mem.Allocator, prefix: []const u8, rest: []const u8) ![]const u8 {
    std.debug.assert(prefix.len > 0);
    std.debug.assert(rest.len > 0);

    return std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, rest });
}

test "what stays behind" {
    const site: backup.Site = .{
        .io = std.testing.io,
        .database = "publr.db",
        .data_dir = "/site/data",
        .project_dir = "/site",
    };

    try std.testing.expect(left_out(site, "publr.db-wal", "publr.db-wal", .data));
    try std.testing.expect(left_out(site, "publr.db.serve", "publr.db.serve", .data));
    try std.testing.expect(left_out(site, "backups", "backups", .data));
    try std.testing.expect(left_out(site, "plugins/incoming", "incoming", .data));
    try std.testing.expect(left_out(site, "media/.cache", ".cache", .data));
    try std.testing.expect(left_out(site, "plugins/shop/zig-out", "zig-out", .project));
    try std.testing.expect(!left_out(site, "media/a/photo.webp", "photo.webp", .data));
    try std.testing.expect(!left_out(site, "plugins/abc.wasm", "abc.wasm", .data));
    try std.testing.expect(!left_out(site, "secret.key", "secret.key", .data));
    try std.testing.expect(!left_out(site, "apps", "apps", .data));

    const shared: backup.Site = .{
        .io = std.testing.io,
        .database = "publr.db",
        .data_dir = "/drive",
        .project_dir = "/drive",
    };

    try std.testing.expect(left_out(shared, "apps", "apps", .data));
    try std.testing.expect(!left_out(shared, "media", "media", .data));
}
