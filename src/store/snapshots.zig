const std = @import("std");
const db = @import("../lib/db.zig");

pub const kind_len_max: u32 = 64;
pub const document_bytes_max: u32 = 8 << 20;
pub const list_max: u32 = 1000;
pub const revision = "revision";

/// Field order is the column order of every SELECT here: the struct is what
/// `Statement.read` fills.
pub const Row = struct {
    record: []const u8,
    seq: i64,
    kind: []const u8,
    at: i64,
    by: ?[]const u8,
    document: []const u8,
};

/// Keep a frozen copy of a document; answers its sequence number within the record.
pub fn take(
    connection: *db.Db,
    record: []const u8,
    kind: []const u8,
    at: i64,
    by: ?[]const u8,
    document: []const u8,
) db.Error!i64 {
    std.debug.assert(record.len > 0);
    std.debug.assert(kind.len > 0 and kind.len <= kind_len_max);

    var insert = try connection.prepare(
        "INSERT INTO snapshots (record, seq, kind, at, by, document) VALUES (?1, " ++
            "(SELECT coalesce(max(seq), 0) + 1 FROM snapshots WHERE record = ?1), ?2, ?3, ?4, ?5)",
    );
    defer insert.finalize();

    try insert.bind_text(1, record);
    try insert.bind_text(2, kind);
    try insert.bind_int(3, at);
    try insert.bind_optional_text(4, by);
    try insert.bind_text(5, document);
    try insert.exec();

    var select = try connection.prepare("SELECT max(seq) FROM snapshots WHERE record = ?1");
    defer select.finalize();

    try select.bind_text(1, record);

    std.debug.assert(try select.step());

    return select.read_int();
}

pub fn get(
    connection: *db.Db,
    arena: std.mem.Allocator,
    record: []const u8,
    seq: i64,
) db.Error!?Row {
    std.debug.assert(record.len > 0);
    std.debug.assert(seq >= 0);

    var select = try connection.prepare(
        "SELECT record, seq, kind, at, by, document FROM snapshots WHERE record = ?1 AND seq = ?2",
    );
    defer select.finalize();

    try select.bind_text(1, record);
    try select.bind_int(2, seq);

    if (!try select.step()) {
        return null;
    }

    return try select.read(Row, arena);
}

/// Oldest first; `kind` null means every kind.
/// Which of a record's snapshots a page reads: of `kind` (every kind when null), before
/// `before` (0 for the newest), newest first, `limit` of them; the documents only when
/// asked for, the title (`title_field` of each document) always.
pub const Window = struct {
    kind: ?[]const u8 = null,
    before: i64 = 0,
    limit: u32,
    documents: bool = false,
    title_field: []const u8 = "title",
};

/// A snapshot as a page of them lists it.
pub const Listed = struct {
    seq: i64,
    kind: []const u8,
    at: i64,
    by: ?[]const u8,
    title: []const u8,
    document: []const u8,
};

pub fn page(
    connection: *db.Db,
    arena: std.mem.Allocator,
    record: []const u8,
    window: Window,
) db.Error![]Listed {
    std.debug.assert(record.len > 0);
    std.debug.assert(window.limit > 0 and window.limit <= list_max);

    var select = try connection.prepare(
        "SELECT seq, kind, at, by, coalesce(json_extract(document, '$.' || ?5), ''), " ++
            "CASE WHEN ?6 THEN document ELSE '' END FROM snapshots WHERE record = ?1 " ++
            "AND (?2 IS NULL OR kind = ?2) AND (?3 = 0 OR seq < ?3) ORDER BY seq DESC LIMIT ?4",
    );
    defer select.finalize();

    try select.bind_text(1, record);
    try select.bind_optional_text(2, window.kind);
    try select.bind_int(3, window.before);
    try select.bind_int(4, window.limit);
    try select.bind_text(5, window.title_field);
    try select.bind_int(6, @intFromBool(window.documents));

    var rows: std.ArrayList(Listed) = .empty;

    while (try select.step()) {
        std.debug.assert(rows.items.len < window.limit);
        rows.append(arena, try select.read(Listed, arena)) catch return error.OutOfMemory;
    }

    return rows.items;
}

pub fn list(
    connection: *db.Db,
    arena: std.mem.Allocator,
    record: []const u8,
    kind: ?[]const u8,
    limit: u32,
) db.Error![]Row {
    std.debug.assert(record.len > 0);
    std.debug.assert(limit > 0 and limit <= list_max);

    var select = try connection.prepare(
        "SELECT record, seq, kind, at, by, document FROM snapshots WHERE record = ?1 " ++
            "AND (?2 IS NULL OR kind = ?2) ORDER BY seq LIMIT ?3",
    );
    defer select.finalize();

    try select.bind_text(1, record);
    try select.bind_optional_text(2, kind);
    try select.bind_int(3, limit);

    var rows: std.ArrayList(Row) = .empty;

    while (try select.step()) {
        std.debug.assert(rows.items.len < list_max);
        rows.append(arena, try select.read(Row, arena)) catch return error.OutOfMemory;
    }

    return rows.items;
}

/// Drop all but the newest `keep` snapshots of a kind; answers how many went.
pub fn prune(connection: *db.Db, record: []const u8, kind: []const u8, keep: u32) db.Error!u32 {
    std.debug.assert(record.len > 0);
    std.debug.assert(kind.len > 0);

    var statement = try connection.prepare(
        "DELETE FROM snapshots WHERE record = ?1 AND kind = ?2 AND seq NOT IN " ++
            "(SELECT seq FROM snapshots WHERE record = ?1 AND kind = ?2 " ++
            "ORDER BY seq DESC LIMIT ?3)",
    );
    defer statement.finalize();

    try statement.bind_text(1, record);
    try statement.bind_text(2, kind);
    try statement.bind_int(3, keep);
    try statement.exec();

    return connection.changes();
}

pub fn delete_all(connection: *db.Db, record: []const u8) db.Error!u32 {
    std.debug.assert(record.len > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    var statement = try connection.prepare("DELETE FROM snapshots WHERE record = ?1");
    defer statement.finalize();

    try statement.bind_text(1, record);
    try statement.exec();

    return connection.changes();
}

test "take numbers per record, list by kind oldest first, prune keeps the newest" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;

    const first = try take(connection, "e1", revision, 10, "u", "{\"a\":1}");
    const second = try take(connection, "e1", revision, 20, null, "{\"a\":2}");
    try std.testing.expectEqual(@as(i64, 1), first);
    try std.testing.expectEqual(@as(i64, 2), second);
    try std.testing.expectEqual(@as(i64, 3), try take(connection, "e1", "order", 30, null, "{}"));
    try std.testing.expectEqual(@as(i64, 1), try take(connection, "e2", revision, 40, null, "{}"));

    const revisions = try list(connection, arena, "e1", revision, 10);
    try std.testing.expectEqual(@as(usize, 2), revisions.len);
    try std.testing.expectEqualStrings("{\"a\":1}", revisions[0].document);
    try std.testing.expectEqual(@as(usize, 3), (try list(connection, arena, "e1", null, 10)).len);
    try std.testing.expect((try get(connection, arena, "e1", 2)).?.by == null);
    try std.testing.expect(try get(connection, arena, "e1", 9) == null);

    try std.testing.expectEqual(@as(u32, 1), try prune(connection, "e1", revision, 1));
    const remaining = try list(connection, arena, "e1", revision, 10);
    try std.testing.expectEqual(@as(i64, 2), remaining[0].seq);
    try std.testing.expectEqual(@as(u32, 2), try delete_all(connection, "e1"));
}
