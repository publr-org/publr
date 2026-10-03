//! `activity`: one row per top-level write that completed, appended in its transaction and
//! never changed or removed (triggers refuse it). Not indexed beyond its id, which is the
//! order things happened; a list scans back from the newest.

const std = @import("std");
const db = @import("../lib/db.zig");

pub const list_max: u32 = 200;

pub const Row = struct {
    id: i64,
    at: i64,
    actor: []const u8,
    app: []const u8,
    operation: []const u8,
    input: []const u8,
    /// A JSON array of unit names: `record:<id>`, `plugin:<name>`.
    units: []const u8,
    /// A JSON array of the operations it set off inside.
    calls: []const u8,
};

/// What a list keeps: each set filter must hold, `before` pages back.
pub const Filter = struct {
    actor: ?[]const u8 = null,
    operation: ?[]const u8 = null,
    /// A unit the entry changed, exactly: `plugin:greeter`.
    unit: ?[]const u8 = null,
    since: ?i64 = null,
    until: ?i64 = null,
    before: ?i64 = null,
};

pub fn append(connection: *db.Db, row: Row) db.Error!void {
    std.debug.assert(row.operation.len > 0);
    std.debug.assert(row.at >= 0);

    var insert = try connection.prepare("INSERT INTO activity " ++
        "(at, actor, app, operation, input, units, calls) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)");
    defer insert.finalize();

    try insert.bind_int(1, row.at);
    try insert.bind_text(2, row.actor);
    try insert.bind_text(3, row.app);
    try insert.bind_text(4, row.operation);
    try insert.bind_text(5, row.input);
    try insert.bind_text(6, row.units);
    try insert.bind_text(7, row.calls);
    try insert.exec();
}

pub fn list(
    connection: *db.Db,
    arena: std.mem.Allocator,
    filter: Filter,
    limit: u32,
) db.Error![]const Row {
    std.debug.assert(limit > 0 and limit <= list_max);

    var select = try connection.prepare("SELECT id, at, actor, app, operation, input, units, " ++
        "calls FROM activity WHERE (?1 IS NULL OR actor = ?1) AND (?2 IS NULL OR " ++
        "operation = ?2) AND (?3 IS NULL OR EXISTS (SELECT 1 FROM json_each(units) " ++
        "WHERE value = ?3)) AND (?4 IS NULL OR at >= ?4) AND (?5 IS NULL OR at < ?5) " ++
        "AND (?6 IS NULL OR id < ?6) ORDER BY id DESC LIMIT ?7");
    defer select.finalize();

    try select.bind_optional_text(1, filter.actor);
    try select.bind_optional_text(2, filter.operation);
    try select.bind_optional_text(3, filter.unit);
    try bind_optional_int(&select, 4, filter.since);
    try bind_optional_int(&select, 5, filter.until);
    try bind_optional_int(&select, 6, filter.before);
    try select.bind_int(7, limit);

    var rows: std.ArrayList(Row) = .empty;

    while (try select.step()) {
        std.debug.assert(rows.items.len < limit);
        rows.append(arena, try select.read(Row, arena)) catch return error.OutOfMemory;
    }

    return rows.items;
}

pub fn bind_optional_int(statement: anytype, index: u31, value: ?i64) db.Error!void {
    std.debug.assert(index > 0);

    if (value) |number| {
        try statement.bind_int(index, number);
    } else {
        try statement.bind_null(index);
    }
}

test "the logs: appended, never updated or deleted" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const connection = &fixture.connection;

    try append(connection, .{
        .id = 0,
        .at = 1,
        .actor = "system",
        .app = "",
        .operation = "record.save",
        .input = "{}",
        .units = "[]",
        .calls = "[]",
    });

    try @import("errors.zig").append(connection, .{
        .id = 0,
        .at = 2,
        .actor = "system",
        .app = "",
        .operation = "record.save",
        .input = "{}",
        .calls = "[]",
        .@"error" = "Invalid",
        .message = "",
        .failed_in = "",
    });

    const statements = [_][:0]const u8{
        "UPDATE activity SET actor = 'x'",
        "DELETE FROM activity",
        "DELETE FROM errors",
    };

    inline for (statements) |sql| {
        const refused = if (connection.exec(sql)) |_| false else |_| true;

        try std.testing.expect(refused);
    }
}
