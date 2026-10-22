const std = @import("std");
const db = @import("../../lib/db.zig");
const auth = @import("../../lib/auth.zig");
const settings = @import("../../store/settings.zig");
const gate = @import("../gate.zig");

const now_ms: i64 = 1_760_000_000_000;

/// A site in a scratch folder: its database open, the auth state the probes sign in with.
const Site = struct {
    scratch: std.testing.TmpDir,
    arena_state: std.heap.ArenaAllocator,
    root: []const u8,
    db_path: [:0]const u8,
    runtime: db.Runtime,
    connection: db.Db,
    auth: auth.State,

    fn init(site: *Site) !void {
        std.debug.assert(now_ms > 0);

        site.scratch = std.testing.tmpDir(.{});
        site.arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);

        const arena = site.arena_state.allocator();

        try site.scratch.dir.createDirPath(std.testing.io, "data");
        site.root = try site.scratch.dir.realPathFileAlloc(std.testing.io, ".", arena);
        site.db_path = try std.fs.path.joinZ(arena, &.{ site.root, "data", "publr.db" });
        site.runtime = try db.Runtime.init(.{});
        site.connection = try db.open(&site.runtime, site.db_path);
        try site.auth.init(std.testing.allocator, std.testing.io, .{
            .params = auth.password.params_test,
        });
    }

    fn deinit(site: *Site) void {
        std.debug.assert(site.root.len > 0);

        site.auth.deinit();
        site.connection.close();
        site.runtime.deinit();
        site.arena_state.deinit();
        site.scratch.cleanup();
    }

    fn open(site: *Site, release_name: []const u8) !gate.Outcome {
        std.debug.assert(release_name.len > 0);

        return gate.open(
            &site.connection,
            std.testing.io,
            std.testing.allocator,
            &site.runtime,
            &site.auth,
            site.db_path,
            release_name,
            now_ms,
            .{
                .project_dir = site.root,
            },
        );
    }

    fn release(site: *Site) !?[]const u8 {
        std.debug.assert(site.root.len > 0);

        return settings.get(&site.connection, site.arena_state.allocator(), gate.release_key);
    }

    fn backups(site: *Site) !u64 {
        std.debug.assert(site.root.len > 0);

        const arena = site.arena_state.allocator();
        const place = try gate.backup.Site.of(std.testing.io, arena, site.db_path, site.root);

        return (try gate.backup.list(place, arena)).len;
    }
};

test "a new database is made, then opened unchanged by the same release" {
    var site: Site = undefined;
    try site.init();
    defer site.deinit();

    try std.testing.expectEqual(gate.Outcome.fresh, try site.open("0.3.0"));
    try std.testing.expectEqual(gate.Outcome.unchanged, try site.open("0.3.0"));
    try std.testing.expectEqual(@as(u64, 0), try site.backups());
}

test "another release opening it backs the site up first and records itself" {
    var site: Site = undefined;
    try site.init();
    defer site.deinit();

    _ = try site.open("0.3.0");

    try std.testing.expectEqual(gate.Outcome.updated, try site.open("0.3.1"));
    try std.testing.expectEqual(@as(u64, 1), try site.backups());

    const release = try site.release();

    try std.testing.expectEqualStrings("0.3.1", release.?);
    try std.testing.expectEqual(gate.Outcome.unchanged, try site.open("0.3.1"));

    var updated = try site.connection.prepare(
        "SELECT input FROM activity WHERE operation = 'publr.updated'",
    );
    defer updated.finalize();

    try std.testing.expect(try updated.step());

    const Row = struct {
        input: []const u8,
    };
    const row = try updated.read(Row, site.arena_state.allocator());

    try std.testing.expectEqualStrings("{\"from\":\"0.3.0\",\"to\":\"0.3.1\"}", row.input);
}

test "a database from before releases recorded themselves is rebuilt to this shape" {
    var site: Site = undefined;
    try site.init();
    defer site.deinit();

    _ = try site.open("0.3.0");

    // The dashboard on 2026-10-06: `users.role` left NOT NULL after the code stopped
    // writing it, and no release recorded.
    try site.connection.exec("DELETE FROM settings WHERE key = 'publr.release'");
    try site.connection.exec("ALTER TABLE users ADD COLUMN role TEXT NOT NULL DEFAULT 'x'");
    try site.connection.exec("CREATE TABLE users_new AS SELECT * FROM users");
    try site.connection.exec("PRAGMA foreign_keys = OFF");
    try site.connection.exec("DROP TABLE users");
    try site.connection.exec(
        "CREATE TABLE users (id TEXT PRIMARY KEY, email TEXT NOT NULL UNIQUE, " ++
            "display_name TEXT NOT NULL, password_hash TEXT, password_token_hash BLOB, " ++
            "password_token_expires_at INTEGER, created_at INTEGER NOT NULL, " ++
            "updated_at INTEGER NOT NULL, role TEXT NOT NULL) STRICT",
    );
    try site.connection.exec("PRAGMA foreign_keys = ON");

    try std.testing.expectEqual(gate.Outcome.adopted, try site.open("0.3.0"));
    try std.testing.expect(!try db.schema.has_column(&site.connection, "users", "role"));
    try std.testing.expectEqual(gate.Outcome.unchanged, try site.open("0.3.0"));
}

test "a column this release needs and no migration made is refused, nothing changed" {
    var site: Site = undefined;
    try site.init();
    defer site.deinit();

    _ = try site.open("0.3.0");

    try site.connection.exec("ALTER TABLE views DROP COLUMN query");

    try std.testing.expectError(error.DatabaseRefused, site.open("0.3.1"));

    const release = try site.release();

    try std.testing.expectEqualStrings("0.3.0", release.?);
}

test "a database a newer release migrated one-way is refused" {
    var site: Site = undefined;
    try site.init();
    defer site.deinit();

    _ = try site.open("0.3.0");

    try site.connection.exec(
        "INSERT INTO migrations VALUES ('publr', '9.0.0', 'abc', 1, 1); " ++
            "UPDATE settings SET value = '9.0.0' WHERE key = 'publr.release'",
    );

    try std.testing.expectError(error.DatabaseRefused, site.open("0.3.0"));

    try site.connection.exec("UPDATE migrations SET one_way = 0");

    try std.testing.expectEqual(gate.Outcome.updated, try site.open("0.3.0"));
}

test "a table a release added is made without a migration" {
    var site: Site = undefined;
    try site.init();
    defer site.deinit();

    _ = try site.open("0.3.0");

    try site.connection.exec("DROP TABLE secrets");

    try std.testing.expectEqual(gate.Outcome.updated, try site.open("0.3.0"));
    try std.testing.expect(try db.schema.has_table(&site.connection, "secrets"));
}
