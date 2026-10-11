const std = @import("std");
const db = @import("../db.zig");
const shape = @import("shape.zig");

const scratch_table = "publr_rebuild";

/// `table` remade in `connection` the way `expected` has it, every row kept in the columns
/// both have: SQLite's documented way of changing a table (new table, copy, drop, rename,
/// indexes and triggers made again). The caller holds a transaction with foreign keys off
/// and checks them before it commits. A column only `expected` has must take a default or
/// allow NULL while rows exist, or the copy fails and nothing changes.
pub fn rebuild(
    connection: *db.Db,
    expected: *db.Db,
    arena: std.mem.Allocator,
    table: []const u8,
) !void {
    std.debug.assert(connection.transaction_depth >= 1);
    std.debug.assert(table.len > 0);

    const create = try statement_of(expected, arena, "table", table) orelse return error.Missing;
    const prefix = try std.fmt.allocPrint(arena, "CREATE TABLE {s}", .{table});

    if (!std.mem.startsWith(u8, create, prefix)) {
        return error.Unexpected;
    }

    const shared = try shared_columns(connection, expected, arena, table);

    try run(connection, try std.fmt.allocPrint(arena, "CREATE TABLE {s}{s}", .{
        scratch_table,
        create[prefix.len..],
    }));
    try run(connection, try std.fmt.allocPrint(
        arena,
        "INSERT INTO {s} ({s}) SELECT {s} FROM {s}",
        .{ scratch_table, shared, shared, table },
    ));
    try run(connection, try std.fmt.allocPrint(arena, "DROP TABLE {s}", .{table}));
    try run(connection, try std.fmt.allocPrint(
        arena,
        "ALTER TABLE {s} RENAME TO {s}",
        .{ scratch_table, table },
    ));

    for (try objects_of(expected, arena, table)) |sql| {
        try run(connection, sql);
    }
}

/// The columns both shapes of `table` have, as a list for SQL.
fn shared_columns(
    connection: *db.Db,
    expected: *db.Db,
    arena: std.mem.Allocator,
    table: []const u8,
) ![]const u8 {
    std.debug.assert(table.len > 0);
    std.debug.assert(connection != expected);

    const live = try shape.read(connection, arena);
    const wanted = try shape.read(expected, arena);
    const live_table = live.table(table) orelse return error.Missing;
    const wanted_table = wanted.table(table) orelse return error.Missing;

    var list: std.ArrayList(u8) = .empty;

    for (wanted_table.columns) |column| {
        for (live_table.columns) |other| {
            if (std.mem.eql(u8, column.name, other.name)) {
                const separator = if (list.items.len > 0) ", " else "";

                try list.print(arena, "{s}\"{s}\"", .{ separator, column.name });
            }
        }
    }

    if (list.items.len == 0) {
        return error.Unexpected;
    }

    return list.items;
}

fn statement_of(
    connection: *db.Db,
    arena: std.mem.Allocator,
    kind: []const u8,
    name: []const u8,
) !?[]const u8 {
    std.debug.assert(kind.len > 0);
    std.debug.assert(name.len > 0);

    var select = try connection.prepare(
        "SELECT sql FROM sqlite_schema WHERE type = ?1 AND name = ?2",
    );
    defer select.finalize();

    try select.bind_text(1, kind);
    try select.bind_text(2, name);

    if (!try select.step()) {
        return null;
    }

    const Row = struct {
        sql: []const u8,
    };

    return (try select.read(Row, arena)).sql;
}

fn objects_of(expected: *db.Db, arena: std.mem.Allocator, table: []const u8) ![]const []const u8 {
    std.debug.assert(table.len > 0);
    std.debug.assert(shape.objects_max > 0);

    var select = try expected.prepare(
        "SELECT sql FROM sqlite_schema WHERE tbl_name = ?1 " ++
            "AND type IN ('index', 'trigger') AND sql IS NOT NULL ORDER BY type, name",
    );
    defer select.finalize();

    try select.bind_text(1, table);

    var statements: std.ArrayList([]const u8) = .empty;
    const Row = struct {
        sql: []const u8,
    };

    while (try select.step()) {
        if (statements.items.len == shape.objects_max) {
            return error.TooBig;
        }

        try statements.append(arena, (try select.read(Row, arena)).sql);
    }

    return statements.items;
}

/// One statement from `schema.sql`'s own text, as SQLite keeps it, or made from names
/// SQLite reported: never from data.
fn run(connection: *db.Db, sql: []const u8) !void {
    std.debug.assert(sql.len > 0);
    std.debug.assert(connection.transaction_depth >= 1);

    var statement = try connection.prepare_dynamic(sql);
    defer statement.finalize();

    try statement.exec();
}

test "a drifted table is remade to the expected shape, its rows kept" {
    var runtime = try db.Runtime.init(.{});
    defer runtime.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var live = try db.open(&runtime, ":memory:");
    defer live.close();
    var expected = try db.open(&runtime, ":memory:");
    defer expected.close();

    try expected.exec(
        "CREATE TABLE users (id TEXT PRIMARY KEY, email TEXT NOT NULL, " ++
            "note TEXT NOT NULL DEFAULT '') STRICT; CREATE INDEX users_email ON users (email)",
    );
    try live.exec(
        "CREATE TABLE users (id TEXT PRIMARY KEY, email TEXT NOT NULL, role TEXT NOT NULL) " ++
            "STRICT; INSERT INTO users VALUES ('u1', 'a@example.com', 'admin')",
    );

    var transaction = try live.transaction();
    defer transaction.rollback();

    try rebuild(&live, &expected, arena, "users");
    try transaction.commit();

    const differences = try shape.compare(
        arena,
        try shape.read(&expected, arena),
        try shape.read(&live, arena),
    );

    try std.testing.expectEqual(@as(usize, 0), differences.len);

    var select = try live.prepare("SELECT email FROM users WHERE id = 'u1'");
    defer select.finalize();

    try std.testing.expect(try select.step());
}

test "a new column with no default fails the copy while rows exist" {
    var runtime = try db.Runtime.init(.{});
    defer runtime.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var live = try db.open(&runtime, ":memory:");
    defer live.close();
    var expected = try db.open(&runtime, ":memory:");
    defer expected.close();

    try expected.exec("CREATE TABLE a (id TEXT PRIMARY KEY, size INTEGER NOT NULL)");
    try live.exec("CREATE TABLE a (id TEXT PRIMARY KEY); INSERT INTO a VALUES ('x')");

    var transaction = try live.transaction();
    defer transaction.rollback();

    const failed = rebuild(&live, &expected, arena_state.allocator(), "a");

    try std.testing.expectError(error.Constraint, failed);
}
