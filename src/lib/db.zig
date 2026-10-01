//! The database as Publr opens it: `publr_sqlite`, the PRAGMAs every connection gets,
//! the schema, and the fixture every store test starts from.

const std = @import("std");
const sqlite = @import("publr_sqlite");
const deps = @import("deps.zig");

pub const schema = @import("db/schema.zig");

pub const Runtime = sqlite.Runtime;
pub const Db = sqlite.Database;
pub const Statement = sqlite.Statement;
pub const Transaction = sqlite.Transaction;
pub const Blob = sqlite.Blob;
pub const Any = sqlite.Any;
pub const Error = sqlite.Error;
pub const heap_bytes_min = sqlite.heap_bytes_min;

/// How long a statement waits for another process (the CLI next to a running server)
/// to release the write lock before the caller hears `error.Busy`.
pub const busy_timeout_ms: u32 = 5_000;

pub fn open(runtime: *Runtime, path: [*:0]const u8) Error!Db {
    std.debug.assert(path[0] != 0);
    std.debug.assert(busy_timeout_ms <= sqlite.busy_timeout_ms_max);

    var connection = try Db.open(runtime, path, .{ .busy_timeout_ms = busy_timeout_ms });
    errdefer connection.close();

    try connection.exec("PRAGMA journal_mode = WAL");
    try connection.exec("PRAGMA synchronous = NORMAL");
    try connection.exec("PRAGMA foreign_keys = ON");
    try connection.exec("PRAGMA temp_store = MEMORY");

    return connection;
}

/// The whole database written to a new file at `path`: one read transaction, so the copy
/// is consistent while another process writes.
pub fn copy_to(connection: *Db, path: []const u8) Error!void {
    std.debug.assert(path.len > 0);
    std.debug.assert(connection.transaction_depth == 0);

    var statement = try connection.prepare("VACUUM INTO ?1");
    defer statement.finalize();

    try statement.bind_text(1, path);
    // SQLite counts VACUUM and ATTACH as read-only statements, which `exec` refuses.
    const row = try statement.step();

    std.debug.assert(!row);
}

/// These tables, with their rows, written to a new database at `path`.
pub fn copy_tables_to(
    connection: *Db,
    path: []const u8,
    comptime tables: []const []const u8,
) Error!void {
    std.debug.assert(path.len > 0);
    comptime std.debug.assert(tables.len > 0);

    var attach = try connection.prepare("ATTACH DATABASE ?1 AS copy");
    defer attach.finalize();

    try attach.bind_text(1, path);

    const row = try attach.step();

    std.debug.assert(!row);
    defer connection.exec("DETACH DATABASE copy") catch |err| {
        std.log.warn("detach {s}: {t}", .{ path, err });
    };

    inline for (tables) |table| {
        try connection.exec("CREATE TABLE copy." ++ table ++ " AS SELECT * FROM main." ++ table);
    }
}

pub const testing = struct {
    pub const Fixture = struct {
        runtime: Runtime,
        connection: Db,

        pub fn init(fixture: *Fixture) !void {
            std.debug.assert(schema.tables.len > 0);
            std.debug.assert(busy_timeout_ms > 0);

            fixture.runtime = try Runtime.init(.{});
            errdefer fixture.runtime.deinit();

            fixture.connection = try open(&fixture.runtime, ":memory:");
            errdefer fixture.connection.close();

            try schema.apply(&fixture.connection);
            _ = try deps.Index.open(&fixture.connection, .{ .quiet_ms = deps.quiet_ms });
        }

        pub fn deinit(fixture: *Fixture) void {
            std.debug.assert(fixture.connection.transaction_depth == 0);
            std.debug.assert(fixture.runtime.open_count == 1);

            fixture.connection.close();
            fixture.runtime.deinit();
            fixture.* = undefined;
        }
    };
};

test "open enforces foreign keys and journals in WAL" {
    var fixture: testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const connection = &fixture.connection;

    try connection.exec("CREATE TABLE p (id INTEGER PRIMARY KEY)");
    try connection.exec("CREATE TABLE ch (p_id INTEGER REFERENCES p(id))");
    const orphan = connection.exec("INSERT INTO ch (p_id) VALUES (42)");
    try std.testing.expectError(error.Constraint, orphan);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var select = try connection.prepare("PRAGMA journal_mode");
    defer select.finalize();

    const Mode = struct { mode: []const u8 };

    try std.testing.expect(try select.step());
    const journal = try select.read(Mode, arena_state.allocator());
    try std.testing.expectEqualStrings("memory", journal.mode);
}

test "a copy holds every row, and a table copy only the tables named" {
    var fixture: testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    const dir = try scratch.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const whole = try std.fs.path.joinZ(arena, &.{ dir, "whole.db" });
    const some = try std.fs.path.joinZ(arena, &.{ dir, "some.db" });
    const connection = &fixture.connection;

    try connection.exec("CREATE TABLE kept (id INTEGER PRIMARY KEY)");
    try connection.exec("CREATE TABLE left (id INTEGER PRIMARY KEY)");
    try connection.exec("INSERT INTO kept (id) VALUES (1), (2)");
    try connection.exec("INSERT INTO left (id) VALUES (3)");
    try copy_to(connection, whole);
    try copy_tables_to(connection, some, &.{"kept"});

    var whole_copy = try open(&fixture.runtime, whole);
    defer whole_copy.close();
    try std.testing.expectEqual(@as(i64, 1), try count(&whole_copy, "SELECT count(*) FROM left"));

    var some_copy = try open(&fixture.runtime, some);
    defer some_copy.close();
    try std.testing.expectEqual(@as(i64, 2), try count(&some_copy, "SELECT count(*) FROM kept"));
    const tables = "SELECT count(*) FROM sqlite_master WHERE type = 'table'";
    try std.testing.expectEqual(@as(i64, 1), try count(&some_copy, tables));
}

fn count(connection: *Db, comptime sql: []const u8) !i64 {
    std.debug.assert(sql.len > 0);
    std.debug.assert(connection.transaction_depth == 0);

    var statement = try connection.prepare(sql);
    defer statement.finalize();

    try std.testing.expect(try statement.step());

    return statement.read_int();
}

test {
    std.testing.refAllDecls(@This());
}
