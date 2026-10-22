const std = @import("std");
const db = @import("../../lib/db.zig");
const backup = @import("../gate/backup.zig");
const bundle = @import("../bundle.zig");

const Scratch = struct {
    folder: std.testing.TmpDir,
    root: []const u8,

    fn init(arena: std.mem.Allocator) !Scratch {
        std.debug.assert(bundle.format_version > 0);

        var folder = std.testing.tmpDir(.{});
        errdefer folder.cleanup();

        const root = try folder.dir.realPathFileAlloc(std.testing.io, ".", arena);

        std.debug.assert(std.fs.path.isAbsolute(root));

        return .{
            .folder = folder,
            .root = root,
        };
    }

    fn write(scratch: *Scratch, path: []const u8, data: []const u8) !void {
        std.debug.assert(path.len > 0);
        std.debug.assert(!std.fs.path.isAbsolute(path));

        if (std.fs.path.dirname(path)) |parent| {
            try scratch.folder.dir.createDirPath(std.testing.io, parent);
        }

        try scratch.folder.dir.writeFile(std.testing.io, .{
            .sub_path = path,
            .data = data,
        });
    }

    fn has(scratch: *Scratch, path: []const u8) bool {
        std.debug.assert(path.len > 0);
        std.debug.assert(!std.fs.path.isAbsolute(path));

        scratch.folder.dir.access(std.testing.io, path, .{}) catch return false;

        return true;
    }

    fn site(scratch: *const Scratch, arena: std.mem.Allocator) !backup.Site {
        std.debug.assert(scratch.root.len > 0);
        std.debug.assert(std.fs.path.isAbsolute(scratch.root));

        return .{
            .io = std.testing.io,
            .database = "publr.db",
            .data_dir = try std.fs.path.join(arena, &.{ scratch.root, "data" }),
            .project_dir = scratch.root,
        };
    }
};

const tables =
    \\CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at INTEGER);
    \\CREATE TABLE sessions (id TEXT PRIMARY KEY);
    \\CREATE TABLE devices (id TEXT PRIMARY KEY);
    \\CREATE TABLE records (id TEXT PRIMARY KEY);
    \\INSERT INTO settings VALUES ('publr.release', '0.4.0', 0);
    \\INSERT INTO settings VALUES ('sign_on.issuer', 'http://localhost:8789', 0);
    \\INSERT INTO settings VALUES ('sign_onXissuer', 'kept', 0);
    \\INSERT INTO sessions VALUES ('s1');
    \\INSERT INTO devices VALUES ('d1');
    \\INSERT INTO records VALUES ('r1');
;

fn make_site(scratch: *Scratch, runtime: *db.Runtime, arena: std.mem.Allocator) !void {
    std.debug.assert(scratch.root.len > 0);
    std.debug.assert(tables.len > 0);

    const files = [_][2][]const u8{
        .{ "data/media/a/photo.webp", "pixels" },
        .{ "data/media/.cache/a/thumb.webp", "cached" },
        .{ "data/plugins/abc.wasm", "code" },
        .{ "data/plugins/incoming/half.wasm", "half" },
        .{ "data/backups/old/publr.db", "old" },
        .{ "data/agents/one.log", "log" },
        .{ "data/secret.key", "00ff" },
        .{ "data/publr.db.serve", "8080 key" },
        .{ "apps/www/app.zon", ".{}" },
        .{ "plugins/shop/main.zig", "pub const shop = 1;" },
        .{ "plugins/shop/zig-out/shop.wasm", "built" },
        .{ "publr.zon", ".{ .name = \"ada\" }" },
        .{ "site.json", "{}" },
        .{ "output/index.html", "<p>built</p>" },
    };

    for (files) |file| {
        try scratch.write(file[0], file[1]);
    }

    const path = try std.fs.path.joinZ(arena, &.{ scratch.root, "data", "publr.db" });
    var connection = try db.open(runtime, path);
    defer connection.close();

    try connection.exec(tables);
}

fn count(runtime: *db.Runtime, path: [:0]const u8, comptime sql: []const u8) !i64 {
    std.debug.assert(path.len > 0);
    std.debug.assert(sql.len > 0);

    var connection = try db.open(runtime, path);
    defer connection.close();
    var statement = try connection.prepare(sql);
    defer statement.finalize();

    _ = try statement.step();

    return statement.read_int();
}

test "a packed site unpacks elsewhere as it was, without this machine's things" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var runtime = try db.Runtime.init(.{});
    defer runtime.deinit();
    var source = try Scratch.init(arena);
    defer source.folder.cleanup();
    var target = try Scratch.init(arena);
    defer target.folder.cleanup();

    try make_site(&source, &runtime, arena);

    const file = try std.fs.path.join(arena, &.{ source.root, "ada.site.tar.gz" });
    const made = try bundle.pack(try source.site(arena), arena, file, "ada");

    try std.testing.expectEqualStrings("0.4.0", made.manifest.release);
    try std.testing.expectEqual(@as(u32, 7), made.files);

    const manifest = try bundle.unpack(try target.site(arena), arena, file, .{});

    try std.testing.expectEqualStrings("ada", manifest.name);

    for ([_][]const u8{
        "data/publr.db",   "data/media/a/photo.webp", "data/plugins/abc.wasm",
        "data/secret.key", "apps/www/app.zon",        "plugins/shop/main.zig",
        "publr.zon",
    }) |kept| {
        try std.testing.expect(target.has(kept));
    }

    for ([_][]const u8{
        "data/media/.cache", "data/plugins/incoming", "data/backups",
        "data/agents",       "data/publr.db.serve",   "plugins/shop/zig-out",
        "site.json",         "output",
    }) |left| {
        try std.testing.expect(!target.has(left));
    }

    const database = try std.fs.path.joinZ(arena, &.{ target.root, "data", "publr.db" });

    const sessions = try count(&runtime, database, "SELECT count(*) FROM sessions");
    const devices = try count(&runtime, database, "SELECT count(*) FROM devices");
    const records = try count(&runtime, database, "SELECT count(*) FROM records");
    const settings = try count(&runtime, database, "SELECT count(*) FROM settings");

    try std.testing.expectEqual(@as(i64, 0), sessions);
    try std.testing.expectEqual(@as(i64, 0), devices);
    try std.testing.expectEqual(@as(i64, 1), records);
    try std.testing.expectEqual(@as(i64, 2), settings);

    // Never over a site: the database is there now.
    const again = bundle.unpack(try target.site(arena), arena, file, .{});

    try std.testing.expectError(error.SiteExists, again);
}

test "unpacking refuses what is not a bundle, and a bundle past the limit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var runtime = try db.Runtime.init(.{});
    defer runtime.deinit();
    var source = try Scratch.init(arena);
    defer source.folder.cleanup();
    var target = try Scratch.init(arena);
    defer target.folder.cleanup();

    try source.write("plain.txt", "not a bundle at all");

    const plain = try std.fs.path.join(arena, &.{ source.root, "plain.txt" });
    const refused = bundle.unpack(try target.site(arena), arena, plain, .{});

    try std.testing.expectError(error.NotABundle, refused);
    try make_site(&source, &runtime, arena);

    const file = try std.fs.path.join(arena, &.{ source.root, "ada.site.tar.gz" });

    _ = try bundle.pack(try source.site(arena), arena, file, "ada");

    const big = bundle.unpack(try target.site(arena), arena, file, .{
        .bytes_max = 8,
    });

    try std.testing.expectError(error.TooLarge, big);
    try std.testing.expect(!target.has("data/publr.db"));
}
