//! `publr.Database`: SQL on a built-in plugin's own tables (`host.table`), inside the call's
//! transaction, from `ctx.database()`. What lies behind it is Publr's own connection.
const std = @import("std");
const db = @import("../../lib/db.zig");
// Until `publr.Error` is the public set: the database's own errors among them.
const Error = @import("../../sdk/operation.zig").Error;

pub const Database = struct {
    /// Publr's own: the connection the call runs on.
    connection: *anyopaque,

    fn core(database: Database) *db.Db {
        return @ptrCast(@alignCast(database.connection));
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

        var prepared = try database.core().prepare(sql);
        errdefer prepared.finalize();

        inline for (values, 1..) |value, index| {
            try bind(&prepared, index, value);
        }

        return Statement.of(prepared);
    }

    fn bind(statement: *db.Statement, index: u31, value: anytype) Error!void {
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

        return prepared.bind_text(index, value);
    }

    pub fn bind_optional_text(statement: *Statement, index: u31, value: ?[]const u8) Error!void {
        var prepared = statement.core();

        return prepared.bind_optional_text(index, value);
    }

    pub fn bind_blob(statement: *Statement, index: u31, value: []const u8) Error!void {
        var prepared = statement.core();

        return prepared.bind_blob(index, value);
    }

    pub fn bind_int(statement: *Statement, index: u31, value: i64) Error!void {
        var prepared = statement.core();

        return prepared.bind_int(index, value);
    }

    pub fn bind_real(statement: *Statement, index: u31, value: f64) Error!void {
        var prepared = statement.core();

        return prepared.bind_real(index, value);
    }

    pub fn bind_null(statement: *Statement, index: u31) Error!void {
        var prepared = statement.core();

        return prepared.bind_null(index);
    }

    /// The next row: true while there is one.
    pub fn step(statement: *Statement) Error!bool {
        var prepared = statement.core();

        return prepared.step();
    }

    /// Steps once, for a statement answering no rows.
    pub fn exec(statement: *Statement) Error!void {
        var prepared = statement.core();

        return prepared.exec();
    }

    /// The row as `Row`, a struct with one field per column: integers, floats, bools, text,
    /// each optional for a column that may be NULL. Text lives in `arena`.
    pub fn read(
        statement: *Statement,
        comptime Row: type,
        arena: std.mem.Allocator,
    ) Error!Row {
        var prepared = statement.core();

        return prepared.read(Row, arena);
    }

    /// The row's one column, a number.
    pub fn read_int(statement: *Statement) i64 {
        var prepared = statement.core();

        return prepared.read_int();
    }
};
