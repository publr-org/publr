const std = @import("std");
const db = @import("../db.zig");

pub const sql: [:0]const u8 = @embedFile("schema.sql");
pub const tables = [_][]const u8{
    "settings",
    "migrations",
    "users",
    "user_roles",
    "user_types",
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
    "job_due_internal",
    "scheduled_changes",
    "webhook_deliveries",
    "ledger_accounts",
    "ledger_transfers",
};

pub fn apply(connection: *db.Db) db.Error!void {
    std.debug.assert(sql.len > 0);
    std.debug.assert(connection.transaction_depth <= 1);

    try connection.exec(sql);
    try register_field_groups(connection);
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

test "apply creates every table and is idempotent" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    try apply(&fixture.connection);

    for (tables) |table| try std.testing.expect(try has_table(&fixture.connection, table));

    try std.testing.expect(!try has_table(&fixture.connection, "nope"));
}

test "every table in schema.sql is documented in the schema doc" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const path = "docs/contributing/schema.md";
    const docs = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
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
            std.debug.print("table {s} is not documented in {s}\n", .{ table, path });
            return error.UndocumentedTable;
        }

        seen += 1;
    }

    try std.testing.expectEqual(@as(u32, tables.len), seen);
}
