const std = @import("std");
const db = @import("../../../lib/db.zig");
const left_out = @import("left_out.zig");
const sql = @import("sql.zig");

const Table = db.shape.Table;
const Object = db.shape.Object;
const quote = sql.quote;
const exec = sql.exec;
const column_of = sql.column_of;
const statement_of = sql.statement_of;
const has_statement = sql.has_statement;

/// The name a table is built under before it takes the old one's.
pub const building = "publr_conform";

/// One change `db conform` makes, as its line says it.
pub const Change = struct {
    kind: Kind,
    /// The table rebuilt, the index or trigger dropped or made (`index <name>`), or the
    /// migration forgotten (`<source> <name>`).
    name: []const u8,
    /// For a rebuild: the differences that make it one, as `db check` words them.
    why: []const u8 = "",

    pub const Kind = enum { rebuild, drop, create, nulled, forget };
};

/// What the database holds that this release has no place for, per table: rows its rules
/// refuse (`column` null), or the values of a column it does not have.
pub const LeftOut = struct {
    table: []const u8,
    column: ?[]const u8,
    count: u64,
};

/// What a conform did, in its transaction, and everything it left out as JSON.
pub const Work = struct {
    connection: *db.Db,
    /// The database this release makes: the statements tables and objects are made from.
    expected: *db.Db,
    arena: std.mem.Allocator,
    changes: std.ArrayList(Change) = .empty,
    left_out: std.ArrayList(LeftOut) = .empty,
    /// One JSON object per row left out: `{"table", "key", "values"}`.
    rows: std.ArrayList([]const u8) = .empty,
    /// One JSON object per value left out: `{"table", "column", "key", "value"}`.
    values: std.ArrayList([]const u8) = .empty,

    pub fn count(work: *Work, table_name: []const u8, column: ?[]const u8) !void {
        std.debug.assert(table_name.len > 0);
        std.debug.assert(column == null or column.?.len > 0);

        for (work.left_out.items) |*entry| {
            const same_column = if (entry.column) |name|
                column != null and std.mem.eql(u8, name, column.?)
            else
                column == null;

            if (same_column and std.mem.eql(u8, entry.table, table_name)) {
                entry.count += 1;
                return;
            }
        }

        try work.left_out.append(work.arena, .{
            .table = table_name,
            .column = column,
            .count = 1,
        });
    }
};

/// SQLite's documented rebuild: the expected table made under another name, the columns
/// both have copied row by row (a row its rules refuse is left out), the old one dropped,
/// the new one renamed, and this release's indexes and triggers for it made.
pub fn table(work: *Work, expected: Table, live: Table, objects: []const Object) !void {
    std.debug.assert(work.connection.transaction_depth >= 1);
    std.debug.assert(std.mem.eql(u8, expected.name, live.name));

    const arena = work.arena;
    const name = try quote(arena, live.name);
    const statement = try statement_of(work.expected, arena, "table", expected.name);
    const open = std.mem.indexOfScalar(u8, statement, '(') orelse return error.Sqlite;

    try exec(work.connection, try std.fmt.allocPrint(arena, "CREATE TABLE \"{s}\" {s}", .{
        building,
        statement[open..],
    }));
    try copy_rows(work, expected, live);
    try left_out.leave_out_columns(work, expected, live);

    for (objects) |object| {
        const kept = try has_statement(work.expected, @tagName(object.kind), object.name);

        if (std.mem.eql(u8, object.table, live.name) and !kept) {
            try work.changes.append(arena, .{
                .kind = .drop,
                .name = try std.fmt.allocPrint(arena, "{t} {s}", .{ object.kind, object.name }),
            });
        }
    }

    try exec(work.connection, try std.fmt.allocPrint(arena, "DROP TABLE {s}", .{name}));
    try exec(work.connection, try std.fmt.allocPrint(arena, "ALTER TABLE \"{s}\" RENAME TO {s}", .{
        building,
        name,
    }));
    try make_objects(work, live.name);
}

/// The indexes and triggers this release has on `table_name`, made from its statements.
fn make_objects(work: *Work, table_name: []const u8) !void {
    std.debug.assert(table_name.len > 0);
    std.debug.assert(work.connection.transaction_depth >= 1);

    const Row = struct {
        sql: []const u8,
    };
    var select = try work.expected.prepare(
        "SELECT sql FROM sqlite_schema WHERE type IN ('index', 'trigger') " ++
            "AND tbl_name = ?1 AND sql IS NOT NULL ORDER BY type, name",
    );
    defer select.finalize();

    try select.bind_text(1, table_name);

    while (try select.step()) {
        try exec(work.connection, (try select.read(Row, work.arena)).sql);
    }
}

fn copy_rows(work: *Work, expected: Table, live: Table) !void {
    std.debug.assert(work.connection.transaction_depth >= 1);
    std.debug.assert(expected.columns.len > 0);

    const arena = work.arena;
    const columns = try copied_columns(work, expected, live);

    // A table whose INTEGER PRIMARY KEY is its rowid keeps it by that column.
    const rowid = if (integer_key(expected)) "" else "rowid, ";
    var insert = try work.connection.prepare_dynamic(try std.fmt.allocPrint(
        arena,
        "INSERT INTO \"{s}\" ({s}{s}) SELECT {s}{s} FROM {s} WHERE rowid = ?1",
        .{ building, rowid, columns.targets, rowid, columns.sources, try quote(arena, live.name) },
    ));
    defer insert.finalize();
    var rows = try work.connection.prepare_dynamic(try std.fmt.allocPrint(
        arena,
        "SELECT rowid FROM {s} ORDER BY rowid",
        .{try quote(arena, live.name)},
    ));
    defer rows.finalize();

    while (try rows.step()) {
        const row = rows.read_int();

        try insert.bind_int(1, row);
        insert.exec() catch |err| switch (err) {
            error.Constraint => try left_out.leave_out_row(work, live, row),
            else => return err,
        };
        insert.reset();
    }
}

const Copied = struct {
    /// The expected table's columns the database has, quoted and joined.
    targets: []const u8,
    /// What fills each: the database's column, or NULL where it held its default.
    sources: []const u8,
};

/// The columns both tables have. A column the database holds NOT NULL with a default and
/// this release holds nullable with none stood for "none" by that default; this release
/// writes NULL for it, which its uniqueness never counts, so the default is copied as NULL.
fn copied_columns(work: *Work, expected: Table, live: Table) !Copied {
    std.debug.assert(std.mem.eql(u8, expected.name, live.name));
    std.debug.assert(expected.columns.len > 0);

    const arena = work.arena;
    var targets: std.ArrayList(u8) = .empty;
    var sources: std.ArrayList(u8) = .empty;

    for (expected.columns) |column| {
        const found = column_of(live, column.name) orelse continue;
        const name = try quote(arena, column.name);
        const nulled = found.not_null and found.default != null and !column.not_null and
            column.default == null;
        const separator = if (targets.items.len == 0) "" else ", ";

        try targets.print(arena, "{s}{s}", .{ separator, name });

        if (nulled) {
            try sources.print(arena, "{s}NULLIF({s}, {s})", .{ separator, name, found.default.? });
            try work.changes.append(arena, .{
                .kind = .nulled,
                .name = try std.fmt.allocPrint(arena, "{s}.{s}", .{ live.name, column.name }),
                .why = try std.fmt.allocPrint(arena, "{d} values {s} become NULL", .{
                    try read_count(work, try std.fmt.allocPrint(
                        arena,
                        "SELECT count(*) FROM {s} WHERE {s} IS ({s})",
                        .{ try quote(arena, live.name), name, found.default.? },
                    )),
                    found.default.?,
                }),
            });
        } else {
            try sources.print(arena, "{s}{s}", .{ separator, name });
        }
    }

    std.debug.assert(targets.items.len > 0);

    return .{
        .targets = targets.items,
        .sources = sources.items,
    };
}

fn read_count(work: *Work, text: []const u8) !i64 {
    std.debug.assert(text.len > 0);
    std.debug.assert(work.connection.transaction_depth >= 1);

    var select = try work.connection.prepare_dynamic(text);
    defer select.finalize();

    _ = try select.step();

    return select.read_int();
}

fn integer_key(expected: Table) bool {
    std.debug.assert(expected.columns.len > 0);

    var keys: u32 = 0;
    var integer = false;

    for (expected.columns) |column| {
        if (column.primary > 0) {
            keys += 1;
            integer = std.ascii.eqlIgnoreCase(column.type_name, "INTEGER");
        }
    }

    return keys == 1 and integer;
}
