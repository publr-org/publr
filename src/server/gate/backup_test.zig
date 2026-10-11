const std = @import("std");
const db = @import("../../lib/db.zig");
const backup = @import("backup.zig");

const Scratch = struct {
    folder: std.testing.TmpDir,
    root: []const u8,

    fn init(arena: std.mem.Allocator) !Scratch {
        std.debug.assert(backup.kept_max > 0);

        var folder = std.testing.tmpDir(.{});
        errdefer folder.cleanup();

        const root = try folder.dir.realPathFileAlloc(std.testing.io, ".", arena);

        return .{
            .folder = folder,
            .root = root,
        };
    }

    fn write(scratch: *Scratch, path: []const u8, data: []const u8) !void {
        std.debug.assert(path.len > 0);

        if (std.fs.path.dirname(path)) |parent| {
            try scratch.folder.dir.createDirPath(std.testing.io, parent);
        }

        try scratch.folder.dir.writeFile(std.testing.io, .{
            .sub_path = path,
            .data = data,
        });
    }

    fn read(scratch: *Scratch, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
        std.debug.assert(path.len > 0);

        return scratch.folder.dir.readFileAlloc(std.testing.io, path, arena, .limited(1 << 20));
    }
};

fn site_in(arena: std.mem.Allocator, root: []const u8) !backup.Site {
    std.debug.assert(std.fs.path.isAbsolute(root));

    return .{
        .io = std.testing.io,
        .database = "publr.db",
        .data_dir = try std.fs.path.join(arena, &.{ root, "data" }),
        .project_dir = root,
    };
}

fn about(at_ms: i64) backup.About {
    return .{
        .from = "0.3.0",
        .to = "0.4.0",
        .at_ms = at_ms,
        .database = "publr.db",
    };
}

test "a backup holds the database, media, installed plugins and the project, and restores" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch = try Scratch.init(arena);
    defer scratch.folder.cleanup();
    const site = try site_in(arena, scratch.root);

    try scratch.write("data/media/a/photo.webp", "pixels");
    try scratch.write("data/plugins/shop/plugin.wasm", "code");
    try scratch.write("apps/www/app.zon", ".{}");
    try scratch.write("publr.zon", ".{ .plugins = .{} }");

    var runtime = try db.Runtime.init(.{});
    defer runtime.deinit();
    const db_path = try std.fs.path.joinZ(arena, &.{ site.data_dir, "publr.db" });
    var connection = try db.open(&runtime, db_path);

    try connection.exec("CREATE TABLE notes (text TEXT); INSERT INTO notes VALUES ('kept')");

    const made = try backup.make(site, &connection, arena, about(1_760_000_000_000), .{});

    try std.testing.expect(std.mem.endsWith(u8, made, "2025-10-09T085320-0.3.0-to-0.4.0"));

    try connection.exec("DELETE FROM notes");
    connection.close();
    // The media library writes beside a file and renames it in, never in place.
    try scratch.write("data/media/a/photo.webp.next", "changed");
    try scratch.folder.dir.rename(
        "data/media/a/photo.webp.next",
        scratch.folder.dir,
        "data/media/a/photo.webp",
        std.testing.io,
    );
    try scratch.write("apps/www/app.zon", "broken");

    const entries = try backup.list(site, arena);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("0.4.0", entries[0].about.to);
    try backup.restore(site, arena, entries[0]);

    const photo = try scratch.read(arena, "data/media/a/photo.webp");
    const plugin = try scratch.read(arena, "data/plugins/shop/plugin.wasm");

    try std.testing.expectEqualStrings("pixels", photo);
    try std.testing.expectEqualStrings("code", plugin);
    try std.testing.expectEqualStrings(".{}", try scratch.read(arena, "apps/www/app.zon"));

    var restored = try db.open(&runtime, db_path);
    defer restored.close();
    var select = try restored.prepare("SELECT count(*) FROM notes");
    defer select.finalize();

    try std.testing.expect(try select.step());
    try std.testing.expectEqual(@as(i64, 1), select.read_int());
}

test "only the newest backups are kept" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch = try Scratch.init(arena);
    defer scratch.folder.cleanup();
    const site = try site_in(arena, scratch.root);

    try scratch.folder.dir.createDirPath(std.testing.io, "data");

    var runtime = try db.Runtime.init(.{});
    defer runtime.deinit();
    var connection = try db.open(
        &runtime,
        try std.fs.path.joinZ(arena, &.{ site.data_dir, "publr.db" }),
    );
    defer connection.close();

    for (0..backup.kept_max + 2) |index| {
        const at_ms = 1_760_000_000_000 + @as(i64, @intCast(index)) * 1000;

        _ = try backup.make(site, &connection, arena, about(at_ms), .{});
    }

    const entries = try backup.list(site, arena);

    try std.testing.expectEqual(@as(usize, backup.kept_max), entries.len);
    try std.testing.expect(entries[0].about.at_ms > entries[1].about.at_ms);
}
