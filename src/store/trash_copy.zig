//! A copy of what a removal takes, made before it runs, and written back on restore: the
//! rows named, and every row a delete of them takes along (each `ON DELETE CASCADE`,
//! followed outward), parents first, as JSON. Table and column names come from the schema
//! itself (`sqlite_master`, `pragma_table_info`), never from data; values are bound.

const std = @import("std");
const db = @import("../lib/db.zig");

/// Tables one copy reaches, at most.
pub const parts_max: u32 = 64;
const sql_len_max: u32 = 16 << 10;

/// Rows to copy: those of `table` whose `column` is one of `keys` (a JSON array).
pub const Root = struct {
    table: []const u8,
    column: []const u8,
    keys: []const u8,
};

const Cascade = struct {
    child: []const u8,
    column: []const u8,
    parent: []const u8,
    to: []const u8,
};
const Column = struct {
    name: []const u8,
    blob: bool,
};

/// The copy, as JSON: `[{"table":"…","root":true,"rows":[{…},…]},…]`, parents first.
pub fn capture(
    connection: *db.Db,
    arena: std.mem.Allocator,
    roots: []const Root,
    skip: []const []const u8,
) ![]const u8 {
    std.debug.assert(roots.len > 0);
    std.debug.assert(roots.len <= parts_max);

    const cascades = try cascades_of(connection, arena);
    var queue: std.ArrayList(Root) = .empty;
    var root_count: u32 = 0;
    var out: std.ArrayList(u8) = .empty;

    try queue.appendSlice(arena, roots);
    try out.append(arena, '[');

    var index: u32 = 0;

    while (index < queue.items.len) : (index += 1) {
        if (index >= parts_max) {
            return error.TooLarge;
        }

        const part = queue.items[index];
        const rows = try rows_of(connection, arena, part);
        const is_root = root_count < roots.len;

        root_count += @intFromBool(is_root);

        if (index > 0) {
            try out.append(arena, ',');
        }

        try out.print(arena, "{{\"table\":\"{s}\",\"root\":{},\"rows\":{s}}}", .{
            part.table,
            is_root,
            rows,
        });

        for (cascades) |cascade| {
            if (!std.mem.eql(u8, cascade.parent, part.table) or skipped(skip, cascade.child)) {
                continue;
            }

            const keys = try keys_of(connection, arena, part, cascade.to);

            if (!std.mem.eql(u8, keys, "[]")) {
                try queue.append(arena, .{
                    .table = cascade.child,
                    .column = cascade.column,
                    .keys = keys,
                });
            }
        }
    }

    try out.append(arena, ']');

    return out.items;
}

fn skipped(skip: []const []const u8, table: []const u8) bool {
    std.debug.assert(table.len > 0);

    for (skip) |name| {
        if (std.mem.eql(u8, name, table)) {
            return true;
        }
    }

    return false;
}

/// Writes a copy back, parents first. The rows named come back as they were, or the
/// restore fails (something took their place meanwhile); what came along is added where it
/// is missing.
pub fn restore(connection: *db.Db, arena: std.mem.Allocator, copy: []const u8) !void {
    std.debug.assert(copy.len > 0);
    std.debug.assert(connection.transaction_depth >= 1);

    // A part's rows may name one another (a term its parent): checked once all are back.
    try connection.exec("PRAGMA defer_foreign_keys = ON");

    const Part = struct {
        table: []const u8,
        root: bool,
        rows: std.json.Value,
    };
    const parts = try std.json.parseFromSliceLeaky([]const Part, arena, copy, .{
        .allocate = .alloc_always,
    });

    for (parts) |part| {
        const rows = try std.json.Stringify.valueAlloc(arena, part.rows, .{});

        if (std.mem.eql(u8, rows, "[]")) {
            continue;
        }

        const sql = try insert_sql(connection, arena, part.table, part.root);
        var statement = try connection.prepare_dynamic(sql);
        defer statement.finalize();

        try statement.bind_text(1, rows);
        try statement.exec();
    }
}

/// Every foreign key that deletes its rows along with their parent.
fn cascades_of(connection: *db.Db, arena: std.mem.Allocator) ![]const Cascade {
    std.debug.assert(parts_max > 0);

    var select = try connection.prepare(
        "SELECT m.name AS child, f.\"from\" AS \"column\", f.\"table\" AS parent, " ++
            "f.\"to\" AS \"to\" FROM sqlite_master m, pragma_foreign_key_list(m.name) f " ++
            "WHERE m.type = 'table' AND f.on_delete = 'CASCADE'",
    );
    defer select.finalize();

    var found: std.ArrayList(Cascade) = .empty;

    while (try select.step()) {
        try found.append(arena, try select.read(Cascade, arena));
    }

    return found.items;
}

fn columns_of(connection: *db.Db, arena: std.mem.Allocator, table: []const u8) ![]const Column {
    std.debug.assert(table.len > 0);

    var select = try connection.prepare(
        "SELECT name, upper(type) = 'BLOB' AS blob FROM pragma_table_info(?1)",
    );
    defer select.finalize();

    try select.bind_text(1, table);

    var found: std.ArrayList(Column) = .empty;

    while (try select.step()) {
        try found.append(arena, try select.read(Column, arena));
    }

    if (found.items.len == 0) {
        return error.NoSuchTable;
    }

    return found.items;
}

/// The part's rows as a JSON array; blobs as hex.
fn rows_of(connection: *db.Db, arena: std.mem.Allocator, part: Root) ![]const u8 {
    std.debug.assert(part.keys.len > 0);

    const columns = try columns_of(connection, arena, part.table);
    var sql: std.ArrayList(u8) = .empty;

    try sql.appendSlice(arena, "SELECT coalesce(json_group_array(json_object(");

    for (columns, 0..) |column, index| {
        const separator: []const u8 = if (index > 0) ", " else "";
        // A blob as hex; an absent one stays null.
        if (column.blob) {
            try sql.print(arena, "{s}'{s}', nullif(hex(\"{s}\"), '')", .{
                separator,
                column.name,
                column.name,
            });
        } else {
            try sql.print(arena, "{s}'{s}', \"{s}\"", .{ separator, column.name, column.name });
        }
    }

    try sql.print(arena, ")), '[]') AS rows FROM \"{s}\" WHERE \"{s}\" IN " ++
        "(SELECT value FROM json_each(?1))", .{ part.table, part.column });

    return one_text(connection, arena, sql.items, part.keys);
}

/// The values of `column` among the part's rows, as a JSON array.
/// The values of `column` among the rows `part` names, as a JSON array.
pub fn keys_of(
    connection: *db.Db,
    arena: std.mem.Allocator,
    part: Root,
    column: []const u8,
) ![]const u8 {
    std.debug.assert(column.len > 0);

    const sql = try std.fmt.allocPrint(arena, "SELECT coalesce(json_group_array(\"{s}\"), '[]') " ++
        "AS rows FROM \"{s}\" WHERE \"{s}\" IN (SELECT value FROM json_each(?1))", .{
        column,
        part.table,
        part.column,
    });

    return one_text(connection, arena, sql, part.keys);
}

fn insert_sql(
    connection: *db.Db,
    arena: std.mem.Allocator,
    table: []const u8,
    root: bool,
) ![]const u8 {
    std.debug.assert(table.len > 0);

    const columns = try columns_of(connection, arena, table);
    var names: std.ArrayList(u8) = .empty;
    var values: std.ArrayList(u8) = .empty;

    for (columns, 0..) |column, index| {
        const separator: []const u8 = if (index > 0) ", " else "";
        const value = try std.fmt.allocPrint(arena, "json_extract(value, '$.\"{s}\"')", .{
            column.name,
        });

        try names.print(arena, "{s}\"{s}\"", .{ separator, column.name });

        if (column.blob) {
            try values.print(arena, "{s}unhex({s})", .{ separator, value });
        } else {
            try values.print(arena, "{s}{s}", .{ separator, value });
        }
    }

    const verb: []const u8 = if (root) "INSERT" else "INSERT OR IGNORE";
    const sql = try std.fmt.allocPrint(arena, "{s} INTO \"{s}\" ({s}) SELECT {s} FROM " ++
        "json_each(?1)", .{
        verb,
        table,
        names.items,
        values.items,
    });

    if (sql.len > sql_len_max) {
        return error.TooLarge;
    }

    return sql;
}

fn one_text(
    connection: *db.Db,
    arena: std.mem.Allocator,
    sql: []const u8,
    keys: []const u8,
) ![]const u8 {
    std.debug.assert(sql.len > 0);

    if (sql.len > sql_len_max) {
        return error.TooLarge;
    }

    var select = try connection.prepare_dynamic(sql);
    defer select.finalize();

    try select.bind_text(1, keys);

    if (!try select.step()) {
        return "[]";
    }

    const Row = struct {
        rows: []const u8,
    };

    return (try select.read(Row, arena)).rows;
}

test "a copy takes what a delete would take, and comes back whole" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const connection = &fixture.connection;

    try connection.exec("CREATE TABLE kinds (id TEXT PRIMARY KEY, " ++
        "name TEXT NOT NULL UNIQUE) STRICT");
    try connection.exec("CREATE TABLE items (id TEXT PRIMARY KEY, kind TEXT NOT NULL " ++
        "REFERENCES kinds(id) ON DELETE CASCADE, data BLOB) STRICT");
    try connection.exec("INSERT INTO kinds VALUES ('k1', 'recipe'), ('k2', 'post')");
    try connection.exec("INSERT INTO items VALUES ('i1', 'k1', x'00ff'), ('i2', 'k2', NULL)");

    const root: Root = .{
        .table = "kinds",
        .column = "id",
        .keys = "[\"k1\"]",
    };
    const copy = try capture(connection, arena, &.{root}, &.{});

    try connection.exec("DELETE FROM kinds WHERE id = 'k1'");

    var transaction = try connection.transaction();
    try restore(connection, arena, copy);
    try transaction.commit();

    var select = try connection.prepare("SELECT hex(data) AS data FROM items WHERE id = 'i1'");
    defer select.finalize();

    try std.testing.expect(try select.step());

    const Row = struct {
        data: []const u8,
    };

    try std.testing.expectEqualStrings("00FF", (try select.read(Row, arena)).data);
}
