//! The `shared_views` table: saved views administrators made for everyone.

const std = @import("std");
const ids = @import("../lib/id.zig");
const next_id = @import("next_id.zig");
const db = @import("../lib/db.zig");
const view = @import("../model/view.zig");

pub const id_len = ids.len;
pub const count_max: u32 = 64;

pub const Error = db.Error || error{NotFound};

/// One row, in the column order of `select_view`.
pub const View = struct {
    id: []const u8,
    name: []const u8,
    query: []const u8,
    created_by: []const u8,
    created_at: i64,
    updated_at: i64,
};

const select_view = "SELECT id, name, query, created_by, created_at, updated_at FROM shared_views";

pub fn insert(
    connection: *db.Db,
    io: std.Io,
    arena: std.mem.Allocator,
    name: []const u8,
    query: []const u8,
    created_by: []const u8,
    now_ms: i64,
) Error![]const u8 {
    std.debug.assert(name.len > 0 and name.len <= view.name_len_max);
    std.debug.assert(query.len > 0 and query.len <= view.query_bytes_max);

    var id_buffer: [id_len]u8 = undefined;
    const made = try next_id.next("shared_views", connection, io, now_ms, &id_buffer);
    const id = arena.dupe(u8, made) catch return error.OutOfMemory;

    var statement = try connection.prepare(
        "INSERT INTO shared_views (id, name, query, created_by, created_at, updated_at) " ++
            "VALUES (?1, ?2, ?3, ?4, ?5, ?5)",
    );
    defer statement.finalize();

    try statement.bind_text(1, id);
    try statement.bind_text(2, name);
    try statement.bind_text(3, query);
    try statement.bind_text(4, created_by);
    try statement.bind_int(5, now_ms);
    try statement.exec();

    return id;
}

pub fn get(connection: *db.Db, arena: std.mem.Allocator, id: []const u8) Error!?View {
    std.debug.assert(id.len > 0);
    std.debug.assert(id.len <= 128);

    var select = try connection.prepare(select_view ++ " WHERE id = ?1");
    defer select.finalize();

    try select.bind_text(1, id);

    if (!try select.step()) {
        return null;
    }

    return try select.read(View, arena);
}

/// Every one, by name.
pub fn list(connection: *db.Db, arena: std.mem.Allocator) Error![]View {
    std.debug.assert(count_max > 0);

    var select = try connection.prepare(
        select_view ++ " ORDER BY name COLLATE NOCASE, id LIMIT ?1",
    );
    defer select.finalize();

    try select.bind_int(1, count_max);

    var rows: std.ArrayList(View) = .empty;

    while (try select.step()) {
        std.debug.assert(rows.items.len < count_max);
        rows.append(arena, try select.read(View, arena)) catch return error.OutOfMemory;
    }

    return rows.items;
}

pub fn count(connection: *db.Db) Error!u32 {
    std.debug.assert(count_max > 0);

    var select = try connection.prepare("SELECT COUNT(*) AS count FROM shared_views");
    defer select.finalize();

    if (!try select.step()) {
        return 0;
    }

    const Count = struct {
        count: i64,
    };
    var buffer: [64]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const counted = try select.read(Count, fixed.allocator());

    return @intCast(@max(0, counted.count));
}

pub fn update(
    connection: *db.Db,
    id: []const u8,
    name: []const u8,
    query: []const u8,
    now_ms: i64,
) Error!void {
    std.debug.assert(id.len > 0 and name.len > 0 and name.len <= view.name_len_max);
    std.debug.assert(query.len > 0 and query.len <= view.query_bytes_max);

    var statement = try connection.prepare(
        "UPDATE shared_views SET name = ?2, query = ?3, updated_at = ?4 WHERE id = ?1",
    );
    defer statement.finalize();

    try statement.bind_text(1, id);
    try statement.bind_text(2, name);
    try statement.bind_text(3, query);
    try statement.bind_int(4, now_ms);
    try statement.exec();

    if (connection.changes() == 0) {
        return error.NotFound;
    }
}

pub fn delete(connection: *db.Db, id: []const u8) db.Error!bool {
    std.debug.assert(id.len > 0);
    std.debug.assert(id.len <= 128);

    var statement = try connection.prepare("DELETE FROM shared_views WHERE id = ?1");
    defer statement.finalize();

    try statement.bind_text(1, id);
    try statement.exec();

    return connection.changes() > 0;
}

test "insert, get, list by name, update, delete" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;
    const io = std.testing.io;

    const open = try insert(connection, io, arena, "Open orders", "{}", "u_admin", 1_000);
    _ = try insert(connection, io, arena, "all orders", "{}", "u_admin", 2_000);

    try std.testing.expectEqualStrings("u_admin", (try get(connection, arena, open)).?.created_by);
    try std.testing.expectEqualStrings("all orders", (try list(connection, arena))[0].name);
    try std.testing.expectEqual(@as(u32, 2), try count(connection));

    try update(connection, open, "Unpaid", "{\"order\":\"-total\"}", 3_000);
    try std.testing.expectEqualStrings("Unpaid", (try get(connection, arena, open)).?.name);
    try std.testing.expectError(error.NotFound, update(connection, "missing", "x", "{}", 4_000));
    try std.testing.expect(try delete(connection, open));
    try std.testing.expect(!try delete(connection, open));
}
