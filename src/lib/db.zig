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

test {
    std.testing.refAllDecls(@This());
}
