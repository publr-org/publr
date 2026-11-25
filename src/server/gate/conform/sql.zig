const std = @import("std");
const db = @import("../../../lib/db.zig");

const Table = db.shape.Table;

/// The one text column of the row `select` stands on.
pub fn read_text(select: *db.Statement, arena: std.mem.Allocator) ![]const u8 {
    const Row = struct {
        text: []const u8,
    };
    const row = try select.read(Row, arena);

    std.debug.assert(row.text.len > 0);

    return row.text;
}

pub fn column_of(owner: Table, name: []const u8) ?db.shape.Column {
    std.debug.assert(name.len > 0);
    std.debug.assert(owner.columns.len <= db.shape.columns_max);

    for (owner.columns) |column| {
        if (std.mem.eql(u8, column.name, name)) {
            return column;
        }
    }

    return null;
}

/// The statement that made `name` in the database this release expects.
pub fn statement_of(
    expected: *db.Db,
    arena: std.mem.Allocator,
    kind: []const u8,
    name: []const u8,
) ![]const u8 {
    std.debug.assert(kind.len > 0);
    std.debug.assert(name.len > 0);

    var select = try expected.prepare(
        "SELECT sql FROM sqlite_schema WHERE type = ?1 AND name = ?2 AND sql IS NOT NULL",
    );
    defer select.finalize();

    try select.bind_text(1, kind);
    try select.bind_text(2, name);

    if (!try select.step()) {
        return error.Sqlite;
    }

    return read_text(&select, arena);
}

pub fn has_statement(expected: *db.Db, kind: []const u8, name: []const u8) !bool {
    std.debug.assert(kind.len > 0);
    std.debug.assert(name.len > 0);

    var select = try expected.prepare(
        "SELECT 1 FROM sqlite_schema WHERE type = ?1 AND name = ?2",
    );
    defer select.finalize();

    try select.bind_text(1, kind);
    try select.bind_text(2, name);

    return select.step();
}

/// A statement made of names SQLite reported and statements this release's schema holds,
/// never of data from outside.
pub fn exec(connection: *db.Db, sql: []const u8) !void {
    std.debug.assert(sql.len > 0);
    std.debug.assert(connection.transaction_depth >= 1);

    var statement = try connection.prepare_dynamic(sql);
    defer statement.finalize();

    try statement.exec();
}

/// `name` as an SQL identifier.
pub fn quote(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    std.debug.assert(name.len > 0);

    const doubled = try std.mem.replaceOwned(u8, arena, name, "\"", "\"\"");

    return std.fmt.allocPrint(arena, "\"{s}\"", .{doubled});
}

/// `text` as an SQL string.
pub fn literal(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    std.debug.assert(text.len > 0);

    const doubled = try std.mem.replaceOwned(u8, arena, text, "'", "''");

    return std.fmt.allocPrint(arena, "'{s}'", .{doubled});
}
