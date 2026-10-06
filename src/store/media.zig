//! The `media` table: the facts of each file in the library, one row per `media` record.
//! Listing with the explorer's filters and counts is `media/list.zig`.

const std = @import("std");
const db = @import("../lib/db.zig");

pub const list = @import("media/list.zig");

pub const Row = struct {
    record: []const u8,
    filename: []const u8,
    mime_type: []const u8,
    size: i64,
    width: ?i64,
    height: ?i64,
    storage_key: []const u8,
    hash: []const u8,
    private: bool,
    created_at: i64,
};

const columns = "record, filename, mime_type, size, width, height, storage_key, hash, " ++
    "private, created_at";

pub fn insert(connection: *db.Db, row: Row) db.Error!void {
    std.debug.assert(row.record.len > 0 and row.storage_key.len > 0);
    std.debug.assert(row.size >= 0);

    var statement = try connection.prepare(
        "INSERT INTO media (" ++ columns ++ ") VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
    );
    defer statement.finalize();

    try statement.bind_text(1, row.record);
    try statement.bind_text(2, row.filename);
    try statement.bind_text(3, row.mime_type);
    try statement.bind_int(4, row.size);
    try bind_optional_int(&statement, 5, row.width);
    try bind_optional_int(&statement, 6, row.height);
    try statement.bind_text(7, row.storage_key);
    try statement.bind_text(8, row.hash);
    try statement.bind_int(9, @intFromBool(row.private));
    try statement.bind_int(10, row.created_at);
    try statement.exec();
}

fn bind_optional_int(statement: *db.Statement, index: u31, value: ?i64) db.Error!void {
    std.debug.assert(index > 0);
    std.debug.assert(value == null or value.? >= 0);

    if (value) |known| {
        return statement.bind_int(index, known);
    }

    return statement.bind_null(index);
}

pub fn get(connection: *db.Db, arena: std.mem.Allocator, record: []const u8) db.Error!?Row {
    std.debug.assert(record.len > 0);
    std.debug.assert(record.len <= 128);

    var select = try connection.prepare("SELECT " ++ columns ++ " FROM media WHERE record = ?1");
    defer select.finalize();

    try select.bind_text(1, record);

    if (!try select.step()) {
        return null;
    }

    return try select.read(Row, arena);
}

pub fn by_key(connection: *db.Db, arena: std.mem.Allocator, key: []const u8) db.Error!?Row {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= 256);

    var select = try connection.prepare(
        "SELECT " ++ columns ++ " FROM media WHERE storage_key = ?1",
    );
    defer select.finalize();

    try select.bind_text(1, key);

    if (!try select.step()) {
        return null;
    }

    return try select.read(Row, arena);
}

pub fn set_private(connection: *db.Db, record: []const u8, private: bool) db.Error!void {
    std.debug.assert(record.len > 0);
    std.debug.assert(record.len <= 128);

    var update = try connection.prepare("UPDATE media SET private = ?2 WHERE record = ?1");
    defer update.finalize();

    try update.bind_text(1, record);
    try update.bind_int(2, @intFromBool(private));
    try update.exec();
}

/// Whether some file already holds these exact bytes: an upload of the same file twice.
pub fn by_hash(connection: *db.Db, arena: std.mem.Allocator, hash: []const u8) db.Error!?Row {
    std.debug.assert(hash.len == 64);
    std.debug.assert(std.mem.indexOfScalar(u8, hash, 0) == null);

    var select = try connection.prepare(
        "SELECT " ++ columns ++ " FROM media WHERE hash = ?1 ORDER BY created_at LIMIT 1",
    );
    defer select.finalize();

    try select.bind_text(1, hash);

    if (!try select.step()) {
        return null;
    }

    return try select.read(Row, arena);
}

pub const Focal = struct { across: ?i64, down: ?i64 };

/// The focal point written on a file's live record, for cropping around it.
pub fn focal(connection: *db.Db, arena: std.mem.Allocator, record: []const u8) db.Error!Focal {
    std.debug.assert(record.len > 0);
    std.debug.assert(record.len <= 128);

    var select = try connection.prepare(
        "SELECT (SELECT value FROM record_values WHERE record = ?1 AND slot = 'live' " ++
            "AND field = 'focal_x' AND ordinal = 0), (SELECT value FROM record_values " ++
            "WHERE record = ?1 AND slot = 'live' AND field = 'focal_y' AND ordinal = 0)",
    );
    defer select.finalize();

    try select.bind_text(1, record);

    const stepped = try select.step();

    std.debug.assert(stepped);

    return try select.read(Focal, arena);
}

/// The files filed straight in a folder, not through one below it.
pub fn filed_in(
    connection: *db.Db,
    arena: std.mem.Allocator,
    folder: []const u8,
) db.Error![]const []const u8 {
    std.debug.assert(folder.len > 0);
    std.debug.assert(folder.len <= 128);

    var select = try connection.prepare(
        "SELECT t.record FROM record_terms t JOIN media m ON m.record = t.record " ++
            "WHERE t.term = ?1 AND t.slot = 'live' AND t.field = 'media_folders' " ++
            "AND t.explicit = 1 LIMIT 10000",
    );
    defer select.finalize();

    try select.bind_text(1, folder);

    var found: std.ArrayList([]const u8) = .empty;

    while (try select.step()) {
        const row = try select.read(struct { record: []const u8 }, arena);

        try found.append(arena, row.record);
    }

    return found.items;
}

test "media rows: insert, read by record, key and hash, flip privacy, gone with the record" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;

    try list.seed_record(connection, "m1");

    const hash = "a" ** 64;

    try insert(connection, .{
        .record = "m1",
        .filename = "cat.jpg",
        .mime_type = "image/jpeg",
        .size = 4,
        .width = 2,
        .height = 1,
        .storage_key = "2026/10/cat-abc123.jpg",
        .hash = hash,
        .private = false,
        .created_at = 1,
    });

    const found = (try get(connection, arena, "m1")).?;

    try std.testing.expectEqualStrings("cat.jpg", found.filename);
    try std.testing.expectEqual(@as(?i64, 2), found.width);
    try std.testing.expect((try by_key(connection, arena, "2026/10/cat-abc123.jpg")) != null);
    try std.testing.expect((try by_key(connection, arena, "2026/10/dog.jpg")) == null);
    try std.testing.expectEqualStrings("m1", (try by_hash(connection, arena, hash)).?.record);
    try set_private(connection, "m1", true);
    try std.testing.expect((try get(connection, arena, "m1")).?.private);
    try connection.exec("DELETE FROM records WHERE id = 'm1'");
    try std.testing.expect((try get(connection, arena, "m1")) == null);
}
