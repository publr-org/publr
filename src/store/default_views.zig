//! The `default_views` table: where a type's list starts, saved over its plugin's view, by a
//! person for themselves or (no person) by administrators for everyone.

const std = @import("std");
const db = @import("../lib/db.zig");
const view = @import("../model/view.zig");

pub const Error = db.Error;

pub const Saved = struct {
    query: []const u8,
    updated_by: []const u8,
    updated_at: i64,
};

/// A person's default for the type, or everyone's when `user_id` is null.
pub fn get(
    connection: *db.Db,
    arena: std.mem.Allocator,
    user_id: ?[]const u8,
    type_id: []const u8,
) Error!?Saved {
    std.debug.assert(type_id.len > 0);
    std.debug.assert(user_id == null or user_id.?.len > 0);

    var select = try connection.prepare(
        "SELECT query, updated_by, updated_at FROM default_views " ++
            "WHERE ifnull(user_id, '') = ?1 AND type_id = ?2",
    );
    defer select.finalize();

    try select.bind_text(1, user_id orelse "");
    try select.bind_text(2, type_id);

    if (!try select.step()) {
        return null;
    }

    return try select.read(Saved, arena);
}

/// Saves the default, in place of the one there.
pub fn put(
    connection: *db.Db,
    user_id: ?[]const u8,
    type_id: []const u8,
    query: []const u8,
    updated_by: []const u8,
    now_ms: i64,
) Error!void {
    std.debug.assert(type_id.len > 0);
    std.debug.assert(query.len > 0 and query.len <= view.query_bytes_max);

    _ = try remove(connection, user_id, type_id);

    var statement = try connection.prepare(
        "INSERT INTO default_views (user_id, type_id, query, updated_by, updated_at) " ++
            "VALUES (?1, ?2, ?3, ?4, ?5)",
    );
    defer statement.finalize();

    if (user_id) |owner| {
        try statement.bind_text(1, owner);
    } else {
        try statement.bind_null(1);
    }

    try statement.bind_text(2, type_id);
    try statement.bind_text(3, query);
    try statement.bind_text(4, updated_by);
    try statement.bind_int(5, now_ms);
    try statement.exec();
}

/// Whether there was one to remove.
pub fn remove(connection: *db.Db, user_id: ?[]const u8, type_id: []const u8) Error!bool {
    std.debug.assert(type_id.len > 0);
    std.debug.assert(user_id == null or user_id.?.len > 0);

    var statement = try connection.prepare(
        "DELETE FROM default_views WHERE ifnull(user_id, '') = ?1 AND type_id = ?2",
    );
    defer statement.finalize();

    try statement.bind_text(1, user_id orelse "");
    try statement.bind_text(2, type_id);
    try statement.exec();

    return connection.changes() > 0;
}

test "a person's default and everyone's, kept apart; saved again in place; removed" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;
    const io = std.testing.io;
    const users = @import("users.zig");
    const types = @import("content_types.zig");
    const ada = try users.insert(connection, io, arena, .{
        .email = "ada@example.com",
        .display_name = "Ada",
        .password_hash = null,
        .roles = &.{"admin"},
        .now_ms = 0,
    });
    const test_post = @import("../model/content_type.zig").test_post;
    const post = try types.insert(connection, arena, test_post, 0);

    try put(connection, null, post, "{\"order\":\"title\"}", ada, 1_000);
    try put(connection, ada, post, "{\"order\":\"-updated\"}", ada, 2_000);
    try put(connection, ada, post, "{\"per_page\":50}", ada, 3_000);

    const for_everyone = (try get(connection, arena, null, post)).?;
    const for_ada = (try get(connection, arena, ada, post)).?;

    try std.testing.expectEqualStrings("{\"order\":\"title\"}", for_everyone.query);
    try std.testing.expectEqualStrings("{\"per_page\":50}", for_ada.query);
    try std.testing.expect(try remove(connection, ada, post));
    try std.testing.expect((try get(connection, arena, ada, post)) == null);
    try std.testing.expect((try get(connection, arena, null, post)) != null);
}
