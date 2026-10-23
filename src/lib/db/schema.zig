const std = @import("std");
const db = @import("../db.zig");

pub const sql: [:0]const u8 = @embedFile("schema.sql");
pub const tables = [_][]const u8{
    "settings",
    "migrations",
    "users",
    "user_roles",
    "roles",
    "role_grants",
    "role_declarations",
    "sessions",
    "sign_on_tokens",
    "devices",
    "device_requests",
    "identities",
    "content_types",
    "records",
    "record_values",
    "record_search",
    "taxonomies",
    "terms",
    "term_values",
    "term_search",
    "user_values",
    "user_search",
    "record_terms",
    "media",
    "snapshots",
    "views",
    "rail_pins",
    "shared_rail_pins",
    "shared_views",
    "default_views",
    "ai_conversations",
    "ai_steps",
    "ai_pictures",
    "ai_browsers",
    "ai_activity",
    "removals",
    "removal_items",
    "trash",
    "health_kept",
    "secrets",
    "internal_records",
    "internal_record_values",
    "field_groups",
    "sandboxed_plugins",
    "activity",
    "errors",
    "plugin_log",
    "job_queue",
    "job_due",
    "scheduled_transitions",
    "webhook_deliveries",
};

pub fn apply(connection: *db.Db) db.Error!void {
    std.debug.assert(sql.len > 0);
    std.debug.assert(connection.transaction_depth <= 1);

    try connection.exec(sql);
    try add_columns(connection);
    try register_field_groups(connection);
}

/// A column added to a table after the table first shipped. `schema.sql` creates a table
/// only when it is missing, so a database made before keeps its old table: the column is
/// added there, every row kept, its value the default.
const Added = struct {
    table: []const u8,
    column: []const u8,
    definition: []const u8,
};

/// Every column added since its table first shipped, oldest first. A new column on an
/// existing table goes in `schema.sql` and here; never a change to a column already there.
const added_columns = [_]Added{
    .{
        .table = "ai_steps",
        .column = "href",
        .definition = "TEXT NOT NULL DEFAULT ''",
    },
    .{
        .table = "ai_conversations",
        .column = "draft",
        .definition = "TEXT NOT NULL DEFAULT ''",
    },
    .{
        .table = "ai_conversations",
        .column = "cached_tokens",
        .definition = "INTEGER NOT NULL DEFAULT 0",
    },
    .{
        .table = "trash",
        .column = "files",
        .definition = "TEXT NOT NULL DEFAULT ''",
    },
    .{
        .table = "sandboxed_plugins",
        .column = "remove_data",
        .definition = "TEXT NOT NULL DEFAULT '[]'",
    },
    .{
        .table = "rail_pins",
        .column = "hidden",
        .definition = "INTEGER NOT NULL DEFAULT 0",
    },
    .{
        .table = "records",
        .column = "trashed_from",
        .definition = "TEXT NOT NULL DEFAULT ''",
    },
    .{
        .table = "terms",
        .column = "trashed_from",
        .definition = "TEXT NOT NULL DEFAULT ''",
    },
    .{
        .table = "records",
        .column = "requested",
        .definition = "TEXT NOT NULL DEFAULT ''",
    },
    .{
        .table = "records",
        .column = "requested_by",
        .definition = "TEXT",
    },
    .{
        .table = "terms",
        .column = "requested",
        .definition = "TEXT NOT NULL DEFAULT ''",
    },
    .{
        .table = "terms",
        .column = "requested_by",
        .definition = "TEXT",
    },
};

fn add_columns(connection: *db.Db) db.Error!void {
    std.debug.assert(connection.transaction_depth <= 1);
    std.debug.assert(added_columns.len > 0);

    inline for (added_columns) |added| {
        if (!try has_column(connection, added.table, added.column)) {
            try connection.exec("ALTER TABLE " ++ added.table ++ " ADD COLUMN " ++
                added.column ++ " " ++ added.definition);
        }
    }
}

pub fn has_column(connection: *db.Db, table: []const u8, column: []const u8) db.Error!bool {
    std.debug.assert(table.len > 0);
    std.debug.assert(column.len > 0);

    var select = try connection.prepare(
        "SELECT 1 FROM pragma_table_info(?1) WHERE name = ?2",
    );
    defer select.finalize();

    try select.bind_text(1, table);
    try select.bind_text(2, column);

    return select.step();
}

fn register_field_groups(connection: *db.Db) db.Error!void {
    std.debug.assert(connection.transaction_depth <= 1);
    var transaction = try connection.transaction();
    defer transaction.rollback();
    var marker = try connection.prepare(
        "SELECT 1 FROM settings WHERE key = 'schema.field_groups'",
    );
    defer marker.finalize();

    if (!try marker.step()) {
        try connection.exec(@embedFile("field_groups.sql"));
    }

    try transaction.commit();
}

pub fn has_table(connection: *db.Db, table: []const u8) db.Error!bool {
    std.debug.assert(table.len > 0);

    var select = try connection.prepare(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1",
    );
    defer select.finalize();

    try select.bind_text(1, table);

    const found = try select.step();
    std.debug.assert(!found or select.read_int() == 1);

    return found;
}

test "a table made before a column was added gets it, its rows kept" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const connection = &fixture.connection;

    // The table as the first build that had it made it.
    try connection.exec("DROP TABLE ai_steps");
    try connection.exec(
        "CREATE TABLE ai_steps (conversation_id TEXT NOT NULL, position INTEGER NOT NULL, " ++
            "kind TEXT NOT NULL, summary TEXT NOT NULL, detail TEXT NOT NULL, " ++
            "failed INTEGER NOT NULL DEFAULT 0, at INTEGER NOT NULL, " ++
            "PRIMARY KEY (conversation_id, position)) STRICT",
    );
    try connection.exec(
        "INSERT INTO ai_steps (conversation_id, position, kind, summary, detail, at) " ++
            "VALUES ('c', 1, 'ran', 's', 'd', 1)",
    );
    try std.testing.expect(!try has_column(connection, "ai_steps", "href"));

    try apply(connection);
    try apply(connection);

    try std.testing.expect(try has_column(connection, "ai_steps", "href"));

    var select = try connection.prepare("SELECT href FROM ai_steps WHERE position = 1");
    defer select.finalize();

    try std.testing.expect(try select.step());
}

test "apply creates every table and is idempotent" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    try apply(&fixture.connection);

    for (tables) |table| try std.testing.expect(try has_table(&fixture.connection, table));

    try std.testing.expect(!try has_table(&fixture.connection, "nope"));
}

test "every table in schema.sql is documented in docs/schema.md" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const docs = try std.Io.Dir.cwd().readFileAlloc(io, "docs/schema.md", gpa, .limited(1 << 20));
    defer std.testing.allocator.free(docs);

    var statements = std.mem.splitSequence(u8, sql, "CREATE ");
    var seen: u32 = 0;

    while (statements.next()) |statement| {
        const marker = "TABLE IF NOT EXISTS ";
        const start = std.mem.indexOf(u8, statement, marker) orelse continue;
        const rest = statement[start + marker.len ..];
        const end = std.mem.indexOfAny(u8, rest, " (\n") orelse rest.len;
        const table = rest[0..end];
        const heading = try std.fmt.allocPrint(std.testing.allocator, "## `{s}`", .{table});
        defer std.testing.allocator.free(heading);

        if (std.mem.indexOf(u8, docs, heading) == null) {
            std.debug.print("table {s} is not documented in docs/schema.md\n", .{table});
            return error.UndocumentedTable;
        }

        seen += 1;
    }

    try std.testing.expectEqual(@as(u32, tables.len), seen);
}
