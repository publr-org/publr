const std = @import("std");
const db = @import("../db.zig");

pub const compare = @import("shape/compare.zig").compare;
pub const Difference = @import("shape/compare.zig").Difference;

pub const tables_max: u32 = 512;
pub const columns_max: u32 = 256;
pub const objects_max: u32 = 2048;

pub const Column = struct {
    name: []const u8,
    type_name: []const u8,
    not_null: bool,
    default: ?[]const u8,
    /// Its place in the primary key, from 1; 0 when it is not part of it.
    primary: i64,
};

pub const Table = struct {
    name: []const u8,
    /// A virtual table's `CREATE` statement; null for a plain table.
    virtual_sql: ?[]const u8,
    columns: []const Column,
    /// `column -> table(column) on delete action`, one per reference.
    references: []const []const u8,
    /// `unique(email)`, one per uniqueness the table declares.
    uniques: []const []const u8,
};

/// An index or a trigger: its statement, whitespace normalized, is what it is.
pub const Object = struct {
    kind: Kind,
    name: []const u8,
    table: []const u8,
    sql: []const u8,

    pub const Kind = enum { index, trigger };
};

/// What a database holds, as SQLite reports it: the same whether a table was created whole
/// or grew by `ALTER TABLE`, so a database a migration reached and a fresh one compare equal.
pub const Shape = struct {
    tables: []const Table,
    objects: []const Object,

    pub fn table(shape: Shape, name: []const u8) ?Table {
        std.debug.assert(name.len > 0);
        std.debug.assert(shape.tables.len <= tables_max);

        for (shape.tables) |candidate| {
            if (std.mem.eql(u8, candidate.name, name)) {
                return candidate;
            }
        }

        return null;
    }
};

pub fn read(connection: *db.Db, arena: std.mem.Allocator) db.Error!Shape {
    std.debug.assert(tables_max > 0);
    std.debug.assert(objects_max > 0);

    const Row = struct {
        name: []const u8,
        kind: []const u8,
        sql: ?[]const u8,
    };
    var select = try connection.prepare(
        "SELECT list.name, list.type, master.sql FROM pragma_table_list AS list " ++
            "LEFT JOIN sqlite_schema AS master ON master.name = list.name " ++
            "WHERE list.schema = 'main' AND list.type IN ('table', 'virtual') " ++
            "AND list.name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY list.name",
    );
    defer select.finalize();

    var tables: std.ArrayList(Table) = .empty;

    while (try select.step()) {
        if (tables.items.len == tables_max) {
            return error.TooBig;
        }

        const row = try select.read(Row, arena);
        const virtual = std.mem.eql(u8, row.kind, "virtual");

        try tables.append(arena, .{
            .name = row.name,
            .virtual_sql = if (virtual) try normalize(arena, row.sql orelse "") else null,
            .columns = if (virtual) &.{} else try columns_of(connection, arena, row.name),
            .references = try references_of(connection, arena, row.name),
            .uniques = try uniques_of(connection, arena, row.name),
        });
    }

    return .{
        .tables = tables.items,
        .objects = try objects_of(connection, arena),
    };
}

fn columns_of(connection: *db.Db, arena: std.mem.Allocator, table: []const u8) ![]Column {
    std.debug.assert(table.len > 0);
    std.debug.assert(columns_max > 0);

    const Row = struct {
        name: []const u8,
        type_name: []const u8,
        not_null: bool,
        default: ?[]const u8,
        primary: i64,
    };
    var select = try connection.prepare(
        "SELECT name, type, \"notnull\", dflt_value, pk FROM pragma_table_xinfo(?1) " ++
            "ORDER BY cid",
    );
    defer select.finalize();

    try select.bind_text(1, table);

    var columns: std.ArrayList(Column) = .empty;

    while (try select.step()) {
        if (columns.items.len == columns_max) {
            return error.TooBig;
        }

        const row = try select.read(Row, arena);

        try columns.append(arena, .{
            .name = row.name,
            .type_name = row.type_name,
            .not_null = row.not_null,
            .default = row.default,
            .primary = row.primary,
        });
    }

    return columns.items;
}

fn references_of(
    connection: *db.Db,
    arena: std.mem.Allocator,
    table: []const u8,
) ![]const []const u8 {
    std.debug.assert(table.len > 0);
    std.debug.assert(columns_max > 0);

    const Row = struct {
        from: []const u8,
        target: []const u8,
        to: ?[]const u8,
        action: []const u8,
    };
    var select = try connection.prepare(
        "SELECT \"from\", \"table\", \"to\", on_delete FROM pragma_foreign_key_list(?1) " ++
            "ORDER BY id, seq",
    );
    defer select.finalize();

    try select.bind_text(1, table);

    var references: std.ArrayList([]const u8) = .empty;

    while (try select.step()) {
        if (references.items.len == columns_max) {
            return error.TooBig;
        }

        const row = try select.read(Row, arena);

        try references.append(arena, try std.fmt.allocPrint(
            arena,
            "{s} -> {s}({s}) on delete {s}",
            .{ row.from, row.target, row.to orelse "", row.action },
        ));
    }

    return references.items;
}

fn uniques_of(
    connection: *db.Db,
    arena: std.mem.Allocator,
    table: []const u8,
) ![]const []const u8 {
    std.debug.assert(table.len > 0);
    std.debug.assert(columns_max > 0);

    const Row = struct {
        columns: []const u8,
    };
    var select = try connection.prepare(
        "SELECT (SELECT group_concat(info.name, ', ') FROM pragma_index_info(list.name) " ++
            "AS info) FROM pragma_index_list(?1) AS list " ++
            "WHERE list.\"unique\" = 1 AND list.origin IN ('u', 'pk') ORDER BY 1",
    );
    defer select.finalize();

    try select.bind_text(1, table);

    var uniques: std.ArrayList([]const u8) = .empty;

    while (try select.step()) {
        if (uniques.items.len == columns_max) {
            return error.TooBig;
        }

        const row = try select.read(Row, arena);

        try uniques.append(arena, try std.fmt.allocPrint(arena, "unique({s})", .{row.columns}));
    }

    return uniques.items;
}

fn objects_of(connection: *db.Db, arena: std.mem.Allocator) ![]const Object {
    std.debug.assert(objects_max > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    const Row = struct {
        kind: []const u8,
        name: []const u8,
        table: []const u8,
        sql: []const u8,
    };
    var select = try connection.prepare(
        "SELECT type, name, tbl_name, sql FROM sqlite_schema " ++
            "WHERE type IN ('index', 'trigger') AND sql IS NOT NULL ORDER BY name",
    );
    defer select.finalize();

    var objects: std.ArrayList(Object) = .empty;

    while (try select.step()) {
        if (objects.items.len == objects_max) {
            return error.TooBig;
        }

        const row = try select.read(Row, arena);
        const index = std.mem.eql(u8, row.kind, "index");

        try objects.append(arena, .{
            .kind = if (index) .index else .trigger,
            .name = row.name,
            .table = row.table,
            .sql = try normalize(arena, row.sql),
        });
    }

    return objects.items;
}

/// A statement with its whitespace made canonical: one space between words, none around
/// brackets or before a comma, so two layouts of the same statement compare equal.
pub fn normalize(arena: std.mem.Allocator, sql: []const u8) ![]const u8 {
    std.debug.assert(sql.len <= std.math.maxInt(u32));

    var out: std.ArrayList(u8) = try .initCapacity(arena, sql.len);
    var pending_space = false;

    for (sql) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            pending_space = out.items.len > 0;
            continue;
        }

        const tight_before = byte == '(' or byte == ')' or byte == ',';
        const after_open = out.items.len > 0 and out.items[out.items.len - 1] == '(';

        if (pending_space and !tight_before and !after_open) {
            out.appendAssumeCapacity(' ');
        }

        pending_space = false;
        out.appendAssumeCapacity(byte);
    }

    std.debug.assert(out.items.len <= sql.len);

    return out.items;
}

test "normalize ignores layout, keeps words apart" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const laid_out = try normalize(
        arena,
        "CREATE INDEX notes_text\n    ON notes ( text ,  size )\n",
    );
    const flat = try normalize(arena, "CREATE INDEX notes_text ON notes(text, size)");

    try std.testing.expectEqualStrings("CREATE INDEX notes_text ON notes(text, size)", flat);
    try std.testing.expectEqualStrings(flat, laid_out);
    try std.testing.expectEqualStrings("", try normalize(arena, "  \n"));
}

test "a table grown by ALTER reads the same as one created whole" {
    var runtime = try db.Runtime.init(.{});
    defer runtime.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var whole = try db.open(&runtime, ":memory:");
    defer whole.close();
    var grown = try db.open(&runtime, ":memory:");
    defer grown.close();

    try whole.exec("CREATE TABLE a (id TEXT PRIMARY KEY, x TEXT NOT NULL DEFAULT '') STRICT");
    try whole.exec("CREATE INDEX a_x ON a (x)");
    try grown.exec("CREATE TABLE a (id TEXT PRIMARY KEY) STRICT");
    try grown.exec("ALTER TABLE a ADD COLUMN x TEXT NOT NULL DEFAULT ''");
    try grown.exec("CREATE INDEX a_x ON a(x)");

    const expected = try read(&whole, arena);
    const live = try read(&grown, arena);

    try std.testing.expectEqual(@as(usize, 0), (try compare(arena, expected, live)).len);
    try std.testing.expectEqual(@as(usize, 2), expected.table("a").?.columns.len);
    try std.testing.expect(expected.table("b") == null);
}

test "full-text search tables read as one virtual table, not their shadows" {
    var runtime = try db.Runtime.init(.{});
    defer runtime.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var connection = try db.open(&runtime, ":memory:");
    defer connection.close();

    try connection.exec("CREATE VIRTUAL TABLE s USING fts5(body)");

    const shape = try read(&connection, arena_state.allocator());

    try std.testing.expectEqual(@as(usize, 1), shape.tables.len);
    try std.testing.expect(shape.tables[0].virtual_sql != null);
}

test {
    _ = @import("shape/compare.zig");
}
