//! `errors`: one row per top-level call refused or failed, reads too, appended after its
//! rollback and never changed or removed (triggers refuse it). Not indexed beyond its id.

const std = @import("std");
const db = @import("../lib/db.zig");
const activity = @import("activity.zig");

pub const list_max = activity.list_max;

pub const Row = struct {
    id: i64,
    at: i64,
    actor: []const u8,
    app: []const u8,
    operation: []const u8,
    input: []const u8,
    calls: []const u8,
    /// The error's name: `Denied`, `Invalid`, `Failed`.
    @"error": []const u8,
    message: []const u8,
    /// The inner operation the failure came from; empty when it was the call's own.
    failed_in: []const u8,
};

pub const Filter = struct {
    actor: ?[]const u8 = null,
    operation: ?[]const u8 = null,
    since: ?i64 = null,
    until: ?i64 = null,
    before: ?i64 = null,
};

pub fn append(connection: *db.Db, row: Row) db.Error!void {
    std.debug.assert(row.operation.len > 0);
    std.debug.assert(row.@"error".len > 0);

    var insert = try connection.prepare("INSERT INTO errors (at, actor, app, operation, " ++
        "input, calls, error, message, failed_in) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)");
    defer insert.finalize();

    try insert.bind_int(1, row.at);
    try insert.bind_text(2, row.actor);
    try insert.bind_text(3, row.app);
    try insert.bind_text(4, row.operation);
    try insert.bind_text(5, row.input);
    try insert.bind_text(6, row.calls);
    try insert.bind_text(7, row.@"error");
    try insert.bind_text(8, row.message);
    try insert.bind_text(9, row.failed_in);
    try insert.exec();
}

pub fn list(
    connection: *db.Db,
    arena: std.mem.Allocator,
    filter: Filter,
    limit: u32,
) db.Error![]const Row {
    std.debug.assert(limit > 0 and limit <= list_max);

    var select = try connection.prepare("SELECT id, at, actor, app, operation, input, calls, " ++
        "error, message, failed_in FROM errors WHERE (?1 IS NULL OR actor = ?1) AND " ++
        "(?2 IS NULL OR operation = ?2) AND (?3 IS NULL OR at >= ?3) AND " ++
        "(?4 IS NULL OR at < ?4) AND (?5 IS NULL OR id < ?5) ORDER BY id DESC LIMIT ?6");
    defer select.finalize();

    try select.bind_optional_text(1, filter.actor);
    try select.bind_optional_text(2, filter.operation);
    try activity.bind_optional_int(&select, 3, filter.since);
    try activity.bind_optional_int(&select, 4, filter.until);
    try activity.bind_optional_int(&select, 5, filter.before);
    try select.bind_int(6, limit);

    var rows: std.ArrayList(Row) = .empty;

    while (try select.step()) {
        std.debug.assert(rows.items.len < limit);
        rows.append(arena, try select.read(Row, arena)) catch return error.OutOfMemory;
    }

    return rows.items;
}
