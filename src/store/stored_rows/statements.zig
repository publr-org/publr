//! The SQL a put and a read run, built from the schema's columns.

const std = @import("std");
const db = @import("../../lib/db.zig");
const shapes = @import("shapes.zig");

const Table = shapes.Table;
const Shape = shapes.Shape;
const sql_len_max: u32 = 16 << 10;
const columns_max: u32 = 64;

pub const Error = db.Error || error{ Invalid, OutOfMemory };

/// The unit's own row: exactly one, its key the one named, written over what is there.
pub fn put_own(
    connection: *db.Db,
    arena: std.mem.Allocator,
    shape: Shape,
    id: []const u8,
    rows: []const u8,
) Error!void {
    std.debug.assert(id.len > 0);
    std.debug.assert(shape.conflict.len > 0);

    const columns = try columns_of(connection, arena, shape.own.name);
    var updates: std.ArrayList(u8) = .empty;

    for (columns, 0..) |column, index| {
        const separator: []const u8 = if (index > 0) ", " else "";

        try updates.print(arena, "{s}\"{s}\" = excluded.\"{s}\"", .{
            separator,
            column.name,
            column.name,
        });
    }

    const select = try insert_sql(arena, shape.own, columns);
    const sql = try std.fmt.allocPrint(arena, "{s} WHERE json_array_length(?3) = 1 " ++
        "ON CONFLICT ({s}) DO UPDATE SET {s}", .{ select, shape.conflict, updates.items });

    try run(connection, sql, rows, id, shape.own.scope);

    if (connection.changes() != 1) {
        return error.Invalid;
    }
}

/// Rows hanging from the unit, each bound to it whatever its own key says.
pub fn insert(
    connection: *db.Db,
    arena: std.mem.Allocator,
    table: Table,
    id: []const u8,
    rows: []const u8,
) Error!void {
    std.debug.assert(id.len > 0);
    std.debug.assert(table.key.len > 0);

    if (std.mem.eql(u8, rows, "[]")) {
        return;
    }

    const columns = try columns_of(connection, arena, table.name);
    const sql = try std.fmt.allocPrint(arena, "{s} WHERE 1", .{
        try insert_sql(arena, table, columns),
    });

    try run(connection, sql, rows, id, table.scope);
}

/// `INSERT INTO <table> (…) SELECT … FROM json_each(?3)`: the key column takes ?1, the
/// scope column ?2, a BLOB its hex.
fn insert_sql(arena: std.mem.Allocator, table: Table, columns: []const Column) Error![]const u8 {
    std.debug.assert(columns.len > 0);
    std.debug.assert(table.key.len > 0);

    var names: std.ArrayList(u8) = .empty;
    var values: std.ArrayList(u8) = .empty;

    for (columns, 0..) |column, index| {
        const separator: []const u8 = if (index > 0) ", " else "";

        try names.print(arena, "{s}\"{s}\"", .{ separator, column.name });
        try values.print(arena, "{s}", .{separator});
        try given_value(arena, &values, table, column, .insert);
    }

    const sql = try std.fmt.allocPrint(arena, "INSERT INTO \"{s}\" ({s}) SELECT {s} FROM " ++
        "json_each(?3)", .{ table.name, names.items, values.items });

    if (sql.len > sql_len_max) {
        return error.Invalid;
    }

    return sql;
}

const Use = enum {
    insert,
    compare,
};

fn given_value(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    table: Table,
    column: Column,
    use: Use,
) Error!void {
    std.debug.assert(column.name.len > 0);
    std.debug.assert(table.key.len > 0);

    const scoped = table.scope != null and std.mem.eql(u8, column.name, "scope");

    if (std.mem.eql(u8, column.name, table.key)) {
        try out.appendSlice(arena, "?1");
    } else if (scoped) {
        try out.appendSlice(arena, "?2");
    } else if (column.blob) {
        const wrap: []const u8 = if (use == .insert) "unhex" else "upper";

        try out.print(arena, "{s}(json_extract(value, '$.\"{s}\"'))", .{ wrap, column.name });
    } else {
        try out.print(arena, "json_extract(value, '$.\"{s}\"')", .{column.name});
    }
}

/// The given rows as `canonical_stored` would read them once written.
pub fn canonical_given(
    connection: *db.Db,
    arena: std.mem.Allocator,
    table: Table,
    id: []const u8,
    rows: []const u8,
) Error![]const u8 {
    std.debug.assert(id.len > 0);
    std.debug.assert(rows.len > 0);

    if (std.mem.eql(u8, rows, "[]")) {
        return "[]";
    }

    const columns = try columns_of(connection, arena, table.name);
    var fields: std.ArrayList(u8) = .empty;

    for (columns, 0..) |column, index| {
        const separator: []const u8 = if (index > 0) ", " else "";

        try fields.print(arena, "{s}'{s}', ", .{ separator, column.name });
        try given_value(arena, &fields, table, column, .compare);
    }

    const sql = try std.fmt.allocPrint(arena, "SELECT json_group_array(json(row)) AS found " ++
        "FROM (SELECT json_object({s}) AS row FROM json_each(?3) ORDER BY 1)", .{fields.items});

    return single_text(connection, arena, sql, rows, id, table.scope);
}

/// The unit's rows in `table`, each a JSON object by column, ordered by their text.
pub fn canonical_stored(
    connection: *db.Db,
    arena: std.mem.Allocator,
    table: Table,
    id: []const u8,
) Error![]const u8 {
    std.debug.assert(id.len > 0);
    std.debug.assert(table.key.len > 0);

    const columns = try columns_of(connection, arena, table.name);
    var fields: std.ArrayList(u8) = .empty;

    for (columns, 0..) |column, index| {
        const separator: []const u8 = if (index > 0) ", " else "";

        if (column.blob) {
            try fields.print(arena, "{s}'{s}', CASE WHEN \"{s}\" IS NULL THEN NULL " ++
                "ELSE hex(\"{s}\") END", .{ separator, column.name, column.name, column.name });
        } else {
            try fields.print(arena, "{s}'{s}', \"{s}\"", .{ separator, column.name, column.name });
        }
    }

    const scoped: []const u8 = if (table.scope != null) " AND \"scope\" = ?2" else "";
    const sql = try std.fmt.allocPrint(arena, "SELECT json_group_array(json(row)) AS found " ++
        "FROM (SELECT json_object({s}) AS row FROM \"{s}\" WHERE \"{s}\" = ?1{s} " ++
        "ORDER BY 1)", .{ fields.items, table.name, table.key, scoped });

    return single_text(connection, arena, sql, null, id, table.scope);
}

fn single_text(
    connection: *db.Db,
    arena: std.mem.Allocator,
    sql: []const u8,
    rows: ?[]const u8,
    id: []const u8,
    scope: ?[]const u8,
) Error![]const u8 {
    std.debug.assert(sql.len > 0);
    std.debug.assert(id.len > 0);

    if (sql.len > sql_len_max) {
        return error.Invalid;
    }

    var statement = try connection.prepare_dynamic(sql);
    defer statement.finalize();

    try bind_all(&statement, rows, id, scope);

    if (!try statement.step()) {
        return error.Invalid;
    }

    const Found = struct {
        found: []const u8,
    };

    return (try statement.read(Found, arena)).found;
}

pub fn clear(
    connection: *db.Db,
    arena: std.mem.Allocator,
    table: Table,
    id: []const u8,
) Error!void {
    std.debug.assert(table.name.len > 0);
    std.debug.assert(id.len > 0);

    const scoped: []const u8 = if (table.scope != null) " AND \"scope\" = ?2" else "";
    const sql = try std.fmt.allocPrint(arena, "DELETE FROM \"{s}\" WHERE \"{s}\" = ?1{s}", .{
        table.name,
        table.key,
        scoped,
    });
    var statement = try connection.prepare_dynamic(sql);
    defer statement.finalize();

    try bind_all(&statement, null, id, table.scope);
    try statement.exec();
}

fn run(
    connection: *db.Db,
    sql: []const u8,
    rows: []const u8,
    id: []const u8,
    scope: ?[]const u8,
) Error!void {
    std.debug.assert(sql.len > 0);
    std.debug.assert(id.len > 0);

    var statement = try connection.prepare_dynamic(sql);
    defer statement.finalize();

    try bind_all(&statement, rows, id, scope);
    try statement.exec();
}

/// ?1 the unit's key, ?2 its scope when the table has one, ?3 the rows when given.
fn bind_all(
    statement: *db.Statement,
    rows: ?[]const u8,
    id: []const u8,
    scope: ?[]const u8,
) Error!void {
    std.debug.assert(id.len > 0);
    std.debug.assert(scope == null or scope.?.len > 0);

    try statement.bind_text(1, id);

    if (scope) |name| {
        try statement.bind_text(2, name);
    }

    if (rows) |given| {
        try statement.bind_text(3, given);
    }
}

const Column = struct {
    name: []const u8,
    blob: bool,
};

fn columns_of(
    connection: *db.Db,
    arena: std.mem.Allocator,
    table: []const u8,
) Error![]const Column {
    std.debug.assert(table.len > 0);

    var select = try connection.prepare("SELECT name, type FROM pragma_table_info(?1)");
    defer select.finalize();

    try select.bind_text(1, table);

    var found: std.ArrayList(Column) = .empty;
    const Row = struct {
        name: []const u8,
        type: []const u8,
    };

    while (try select.step()) {
        if (found.items.len == columns_max) {
            return error.Invalid;
        }

        const row = try select.read(Row, arena);

        try found.append(arena, .{
            .name = row.name,
            .blob = std.ascii.eqlIgnoreCase(row.type, "BLOB"),
        });
    }

    if (found.items.len == 0) {
        return error.Invalid;
    }

    return found.items;
}
