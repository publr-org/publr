//! `internal_records`: what a plugin keeps for itself, one JSON document per row, always
//! read and written within one plugin's, one app's and one collection's scope.

const std = @import("std");
const ids = @import("../lib/id.zig");
const db = @import("../lib/db.zig");
const model = @import("../model/internal_record.zig");

pub const id_len = ids.len;
pub const list_max: u32 = 200;

pub const Error = db.Error || error{ NotFound, Conflict };

/// Whose records: the plugin, the app (empty for the project's own) and the collection.
pub const Scope = struct { plugin: []const u8, app: []const u8, kind: []const u8 };

/// One row. Field order is the column order of `select_row`.
pub const Row = struct {
    id: []const u8,
    document: []const u8,
    version: i64,
    created_at: i64,
    updated_at: i64,
};

/// Records with this indexed field holding this text.
pub const Match = struct { field: []const u8, value: []const u8 };

const select_row = "SELECT r.id, r.document, r.version, r.created_at, r.updated_at " ++
    "FROM internal_records r";
const in_scope = "r.plugin = ?1 AND r.app = ?2 AND r.kind = ?3";

pub fn insert(
    connection: *db.Db,
    io: std.Io,
    arena: std.mem.Allocator,
    scope: Scope,
    document: []const u8,
    now_ms: i64,
) Error![]const u8 {
    var id_buffer: [id_len]u8 = undefined;
    const id = arena.dupe(u8, ids.random(io, &id_buffer)) catch return error.OutOfMemory;

    try insert_as(connection, scope, id, document, now_ms);

    return id;
}

/// Inserts under an id the caller chose: the printed examples' records.
pub fn insert_as(
    connection: *db.Db,
    scope: Scope,
    id: []const u8,
    document: []const u8,
    now_ms: i64,
) Error!void {
    assert_scope(scope);
    std.debug.assert(document.len > 0 and document.len <= model.document_bytes_max);

    var statement = try connection.prepare(
        "INSERT INTO internal_records " ++
            "(id, plugin, app, kind, document, version, created_at, updated_at) " ++
            "VALUES (?4, ?1, ?2, ?3, ?5, 1, ?6, ?6)",
    );
    defer statement.finalize();

    try bind_scope(&statement, scope);
    try statement.bind_text(4, id);
    try statement.bind_text(5, document);
    try statement.bind_int(6, now_ms);
    try statement.exec();
}

pub fn get(connection: *db.Db, arena: std.mem.Allocator, scope: Scope, id: []const u8) Error!?Row {
    assert_scope(scope);
    std.debug.assert(id.len > 0);

    var select = try connection.prepare(select_row ++ " WHERE " ++ in_scope ++ " AND r.id = ?4");
    defer select.finalize();

    try bind_scope(&select, scope);
    try select.bind_text(4, id);

    if (!try select.step()) {
        return null;
    }

    return try select.read(Row, arena);
}

/// Replaces the document; refused when `expected_version` is given and the row moved.
pub fn update(
    connection: *db.Db,
    scope: Scope,
    id: []const u8,
    document: []const u8,
    expected_version: ?i64,
    now_ms: i64,
) Error!i64 {
    assert_scope(scope);
    std.debug.assert(document.len > 0 and document.len <= model.document_bytes_max);

    var statement = try connection.prepare(
        "UPDATE internal_records SET document = ?5, version = version + 1, updated_at = ?6 " ++
            "WHERE plugin = ?1 AND app = ?2 AND kind = ?3 AND id = ?4 " ++
            "AND (?7 IS NULL OR version = ?7) RETURNING version",
    );
    defer statement.finalize();

    try bind_scope(&statement, scope);
    try statement.bind_text(4, id);
    try statement.bind_text(5, document);
    try statement.bind_int(6, now_ms);

    if (expected_version) |expected| {
        try statement.bind_int(7, expected);
    } else {
        try statement.bind_null(7);
    }

    if (!try statement.step()) {
        return if (expected_version == null) error.NotFound else error.Conflict;
    }

    return statement.read_int();
}

/// Whether the row was there to delete.
pub fn delete(connection: *db.Db, scope: Scope, id: []const u8) Error!bool {
    assert_scope(scope);
    std.debug.assert(id.len > 0);

    var statement = try connection.prepare(
        "DELETE FROM internal_records WHERE plugin = ?1 AND app = ?2 AND kind = ?3 AND id = ?4",
    );
    defer statement.finalize();

    try bind_scope(&statement, scope);
    try statement.bind_text(4, id);
    try statement.exec();

    return connection.changes() == 1;
}

/// A page of the scope's records, newest first; with `match`, only those whose indexed
/// field holds that text.
pub fn list(
    connection: *db.Db,
    arena: std.mem.Allocator,
    scope: Scope,
    match: ?Match,
    limit: u32,
    offset: u32,
) Error![]Row {
    assert_scope(scope);
    std.debug.assert(limit > 0 and limit <= list_max);

    var select = try connection.prepare(select_row ++
        " WHERE " ++ in_scope ++ " AND (?4 IS NULL OR EXISTS (" ++
        "SELECT 1 FROM internal_record_values v WHERE v.record = r.id " ++
        "AND v.field = ?4 AND v.value = ?5)) " ++
        "ORDER BY r.created_at DESC, r.id DESC LIMIT ?6 OFFSET ?7");
    defer select.finalize();

    try bind_scope(&select, scope);

    if (match) |wanted| {
        try select.bind_text(4, wanted.field);
        try select.bind_text(5, wanted.value);
    } else {
        try select.bind_null(4);
        try select.bind_null(5);
    }

    try select.bind_int(6, limit);
    try select.bind_int(7, offset);

    var rows: std.ArrayList(Row) = .empty;

    while (try select.step()) {
        std.debug.assert(rows.items.len < limit);
        rows.append(arena, try select.read(Row, arena)) catch return error.OutOfMemory;
    }

    return rows.items;
}

fn bind_scope(statement: *db.Statement, scope: Scope) Error!void {
    assert_scope(scope);

    try statement.bind_text(1, scope.plugin);
    try statement.bind_text(2, scope.app);
    try statement.bind_text(3, scope.kind);
}

fn assert_scope(scope: Scope) void {
    std.debug.assert(scope.plugin.len > 0);
    std.debug.assert(scope.kind.len > 0 and scope.kind.len <= model.kind_len_max);
}
