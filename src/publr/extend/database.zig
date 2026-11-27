//! `publr.Database`: SQL on a built-in plugin's own tables (`host.table`), inside the call's
//! transaction, from `ctx.database()`. What lies behind it is Publr's own connection.
const std = @import("std");
const db = @import("../../lib/db.zig");
const Error = @import("../operation.zig").Error;
const public_of = @import("../../sdk/operation.zig").public_of;

pub const Database = struct {
    /// Publr's own: the connection the call runs on.
    connection: *anyopaque,

    fn core(database: Database) *db.Db {
        return @ptrCast(@alignCast(database.connection));
    }

    /// Closes a database `Databases.open` opened, given back to `memory`.
    pub fn close(database: Database, memory: std.mem.Allocator) void {
        const connection = database.core();

        connection.close();
        memory.destroy(connection);
    }

    /// The pages built from this database that read any of `keys` (`record:<id>`,
    /// `type:<handle>`), as its dependency index answers: what a change to them rebuilds.
    pub fn affected(
        database: Database,
        memory: std.mem.Allocator,
        keys: []const []const u8,
    ) Error![]const []const u8 {
        std.debug.assert(keys.len <= 1 << 16);

        const deps = @import("../../lib/deps.zig");
        var index: deps.Index = .{
            .db = database.core(),
            .options = .{
                .quiet_ms = deps.quiet_ms,
            },
        };

        return index.affected(memory, keys) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Invalid,
        };
    }

    /// Whether a write is open on this connection: an `.on` middleware heard inside a write
    /// waits for the write to end.
    pub fn in_transaction(database: Database) bool {
        const depth = database.core().transaction_depth;

        std.debug.assert(depth < 1 << 16);

        return depth > 0;
    }

    /// The whole database written to a new file at `path`, as it stands: a copy of the site.
    pub fn copy_to(database: Database, path: []const u8) Error!void {
        std.debug.assert(path.len > 0);

        return db.copy_to(database.core(), path) catch |err| return public_of(err);
    }

    /// Publr's own tables made in this database, as a new site's: for a database a plugin
    /// makes to become a site (a copy, a test's).
    pub fn apply_schema(database: Database) Error!void {
        std.debug.assert(database.core().transaction_depth == 0);

        return db.schema.apply(database.core()) catch |err| return public_of(err);
    }

    /// Runs `sql`, no values, no rows: a schema, a pragma, `BEGIN` / `COMMIT`.
    pub fn run(database: Database, comptime sql: [*:0]const u8) Error!void {
        return database.core().exec(sql) catch |err| return public_of(err);
    }

    /// Runs `sql` with each `?` taken from `values` in order: text, an integer, a bool, a
    /// `publr.Time`, or null.
    pub fn exec(database: Database, comptime sql: []const u8, values: anytype) Error!void {
        comptime std.debug.assert(sql.len > 0);

        var statement = try database.prepare(sql, values);
        defer statement.finalize();

        try statement.exec();
    }

    /// `sql` ready to step through, its `?` filled from `values`.
    pub fn prepare(
        database: Database,
        comptime sql: []const u8,
        values: anytype,
    ) Error!Statement {
        comptime std.debug.assert(sql.len > 0);
        comptime std.debug.assert(values.len < 1 << 15);

        var prepared = database.core().prepare(sql) catch |err| return public_of(err);
        errdefer prepared.finalize();

        inline for (values, 1..) |value, index| {
            bind(&prepared, index, value) catch |err| return public_of(err);
        }

        return Statement.of(prepared);
    }

    fn bind(statement: *db.Statement, index: u31, value: anytype) db.Error!void {
        std.debug.assert(index > 0);

        const Value = @TypeOf(value);

        switch (@typeInfo(Value)) {
            .int, .comptime_int => try statement.bind_int(index, @intCast(value)),
            .bool => try statement.bind_int(index, @intFromBool(value)),
            .null => try statement.bind_null(index),
            .optional => if (value) |given| {
                try bind(statement, index, given);
            } else {
                try statement.bind_null(index);
            },
            .@"struct" => try statement.bind_int(index, value.ms),
            else => try statement.bind_text(index, value),
        }
    }
};

/// Databases besides the call's own, opened by path: another copy of the site's, a file the
/// plugin keeps. From `process.databases()`, kept by a plugin's `State` for the process.
pub const Databases = struct {
    /// Publr's own: the database library's process-wide state.
    runtime: *anyopaque,

    /// The database at `path`, its connection in `memory` until `close`.
    pub fn open(
        databases: Databases,
        memory: std.mem.Allocator,
        path: [:0]const u8,
    ) Error!Database {
        std.debug.assert(path.len > 0);

        const connection = try memory.create(db.Db);
        errdefer memory.destroy(connection);

        const runtime: *db.Runtime = @ptrCast(@alignCast(databases.runtime));

        connection.* = db.open(runtime, path) catch |err| return public_of(err);

        return .{
            .connection = connection,
        };
    }
};

/// A statement on the plugin's tables: bound, stepped through row by row, read, finalized
/// once (`defer statement.finalize()`).
pub const Statement = struct {
    /// Publr's own: the connection and the statement it compiled.
    connection: *anyopaque,
    handle: *anyopaque,

    fn of(prepared: db.Statement) Statement {
        return .{
            .connection = @ptrCast(prepared.db),
            .handle = @ptrCast(prepared.handle),
        };
    }

    fn core(statement: *const Statement) db.Statement {
        return .{
            .db = @ptrCast(@alignCast(statement.connection)),
            .handle = @ptrCast(@alignCast(statement.handle)),
        };
    }

    pub fn finalize(statement: *Statement) void {
        var prepared = statement.core();

        prepared.finalize();
    }

    pub fn reset(statement: *Statement) void {
        var prepared = statement.core();

        prepared.reset();
    }

    pub fn bind_text(statement: *Statement, index: u31, value: []const u8) Error!void {
        var prepared = statement.core();

        return prepared.bind_text(index, value) catch |err| return public_of(err);
    }

    pub fn bind_optional_text(statement: *Statement, index: u31, value: ?[]const u8) Error!void {
        var prepared = statement.core();

        return prepared.bind_optional_text(index, value) catch |err| return public_of(err);
    }

    pub fn bind_blob(statement: *Statement, index: u31, value: []const u8) Error!void {
        var prepared = statement.core();

        return prepared.bind_blob(index, value) catch |err| return public_of(err);
    }

    pub fn bind_int(statement: *Statement, index: u31, value: i64) Error!void {
        var prepared = statement.core();

        return prepared.bind_int(index, value) catch |err| return public_of(err);
    }

    pub fn bind_real(statement: *Statement, index: u31, value: f64) Error!void {
        var prepared = statement.core();

        return prepared.bind_real(index, value) catch |err| return public_of(err);
    }

    pub fn bind_null(statement: *Statement, index: u31) Error!void {
        var prepared = statement.core();

        return prepared.bind_null(index) catch |err| return public_of(err);
    }

    /// The next row: true while there is one.
    pub fn step(statement: *Statement) Error!bool {
        var prepared = statement.core();

        return prepared.step() catch |err| return public_of(err);
    }

    /// Steps once, for a statement answering no rows.
    pub fn exec(statement: *Statement) Error!void {
        var prepared = statement.core();

        return prepared.exec() catch |err| return public_of(err);
    }

    /// The row as `Row`, a struct with one field per column: integers, floats, bools, text,
    /// `publr.Host.Any` for a column of no one type, each optional for a column that may be
    /// NULL. Text lives in `arena`.
    pub fn read(
        statement: *Statement,
        comptime Row: type,
        arena: std.mem.Allocator,
    ) Error!Row {
        const any = @import("database_any.zig");
        var prepared = statement.core();

        if (comptime !any.holds_any(Row)) {
            return prepared.read(Row, arena) catch |err| return public_of(err);
        }

        const core_row = prepared.read(any.CoreRow(Row), arena) catch |err| return public_of(err);

        return any.row_of(Row, core_row);
    }

    /// The row's one column, a number.
    pub fn read_int(statement: *Statement) i64 {
        var prepared = statement.core();

        return prepared.read_int();
    }
};
