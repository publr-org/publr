const std = @import("std");
const ids = @import("../lib/id.zig");
const next_id = @import("next_id.zig");
const db = @import("../lib/db.zig");
const view = @import("../model/view.zig");

pub const id_len = ids.len;
pub const per_user_max: u32 = 64;
pub const list_max: u32 = per_user_max;

pub const Error = db.Error || error{NotFound};

/// One row of `views`: a user's named filters over the content list, as the JSON
/// `model.view.Filters` encodes to. Field order is the column order of `select_view`.
pub const View = struct {
    id: []const u8,
    user_id: []const u8,
    name: []const u8,
    query: []const u8,
    created_at: i64,
    updated_at: i64,
};

const select_view = "SELECT id, user_id, name, query, created_at, updated_at FROM views";

pub fn insert(
    connection: *db.Db,
    io: std.Io,
    arena: std.mem.Allocator,
    user_id: []const u8,
    name: []const u8,
    query: []const u8,
    now_ms: i64,
) Error![]const u8 {
    std.debug.assert(user_id.len > 0 and name.len > 0 and name.len <= view.name_len_max);
    std.debug.assert(query.len > 0 and query.len <= view.query_bytes_max);

    var id_buffer: [id_len]u8 = undefined;
    const made = try next_id.next("views", connection, io, now_ms, &id_buffer);
    const id = arena.dupe(u8, made) catch return error.OutOfMemory;

    var statement = try connection.prepare(
        "INSERT INTO views (id, user_id, name, query, created_at, updated_at) " ++
            "VALUES (?1, ?2, ?3, ?4, ?5, ?5)",
    );
    defer statement.finalize();

    try statement.bind_text(1, id);
    try statement.bind_text(2, user_id);
    try statement.bind_text(3, name);
    try statement.bind_text(4, query);
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

/// A user's views, by name.
pub fn list_by_user(
    connection: *db.Db,
    arena: std.mem.Allocator,
    user_id: []const u8,
) Error![]View {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(list_max > 0);

    var select = try connection.prepare(
        select_view ++ " WHERE user_id = ?1 ORDER BY name COLLATE NOCASE, id LIMIT ?2",
    );
    defer select.finalize();

    try select.bind_text(1, user_id);
    try select.bind_int(2, list_max);

    var rows: std.ArrayList(View) = .empty;

    while (try select.step()) {
        std.debug.assert(rows.items.len < list_max);
        rows.append(arena, try select.read(View, arena)) catch return error.OutOfMemory;
    }

    return rows.items;
}

pub fn count_by_user(connection: *db.Db, user_id: []const u8) Error!u32 {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(per_user_max > 0);

    var select = try connection.prepare("SELECT COUNT(*) AS count FROM views WHERE user_id = ?1");
    defer select.finalize();

    try select.bind_text(1, user_id);

    if (!try select.step()) {
        return 0;
    }

    const Count = struct { count: i64 };
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
        "UPDATE views SET name = ?2, query = ?3, updated_at = ?4 WHERE id = ?1",
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

    var statement = try connection.prepare("DELETE FROM views WHERE id = ?1");
    defer statement.finalize();

    try statement.bind_text(1, id);
    try statement.exec();

    return connection.changes() > 0;
}

/// For the documented examples: give a view the id they name.
pub fn rename(connection: *db.Db, from: []const u8, to: []const u8) db.Error!void {
    std.debug.assert(from.len == id_len);
    std.debug.assert(to.len == id_len);

    var statement = try connection.prepare("UPDATE views SET id = ?1 WHERE id = ?2");
    defer statement.finalize();

    try statement.bind_text(1, to);
    try statement.bind_text(2, from);
    try statement.exec();
}

test "insert, get, list by user in name order, update, delete" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;
    const io = std.testing.io;
    const users = @import("users.zig");
    const ada = try users.insert(connection, io, arena, .{
        .email = "ada@example.com",
        .display_name = "Ada",
        .password_hash = null,
        .roles = &.{"admin"},
        .now_ms = 0,
    });
    const bob = try users.insert(connection, io, arena, .{
        .email = "bob@example.com",
        .display_name = "Bob",
        .password_hash = null,
        .roles = &.{"editor"},
        .now_ms = 0,
    });

    const draft_query = "{\"status\":\"draft\"}";
    const drafts = try insert(connection, io, arena, ada, "My drafts", draft_query, 1_000);
    _ = try insert(connection, io, arena, ada, "all posts", "{\"types\":[\"post\"]}", 2_000);
    _ = try insert(connection, io, arena, bob, "Bob's", "{}", 3_000);

    const found = (try get(connection, arena, drafts)).?;
    try std.testing.expectEqualStrings("My drafts", found.name);
    try std.testing.expectEqualStrings(ada, found.user_id);
    try std.testing.expectEqual(@as(i64, 1_000), found.updated_at);
    try std.testing.expect((try get(connection, arena, "missing")) == null);

    const mine = try list_by_user(connection, arena, ada);
    try std.testing.expectEqual(@as(usize, 2), mine.len);
    try std.testing.expectEqualStrings("all posts", mine[0].name);
    try std.testing.expectEqual(@as(u32, 2), try count_by_user(connection, ada));
    try std.testing.expectEqual(@as(u32, 1), try count_by_user(connection, bob));

    const sorted_query = "{\"status\":\"draft\",\"order\":\"title_asc\"}";
    try update(connection, drafts, "Drafts", sorted_query, 4_000);
    const updated = (try get(connection, arena, drafts)).?;
    try std.testing.expectEqualStrings("Drafts", updated.name);
    try std.testing.expectEqual(@as(i64, 4_000), updated.updated_at);
    try std.testing.expectEqual(@as(i64, 1_000), updated.created_at);
    try std.testing.expectError(error.NotFound, update(connection, "missing", "x", "{}", 5_000));

    try std.testing.expect(try delete(connection, drafts));
    try std.testing.expect(!try delete(connection, drafts));
    try std.testing.expectEqual(@as(usize, 1), (try list_by_user(connection, arena, ada)).len);
}
