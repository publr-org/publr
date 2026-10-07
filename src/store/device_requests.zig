const std = @import("std");
const db = @import("../lib/db.zig");

pub const cleanup_batch: u32 = 256;

pub const Request = struct {
    code_hash: db.Blob,
    user_code: []const u8,
    name: []const u8,
    scope: []const u8,
    state: []const u8,
    user_id: ?[]const u8,
    expires_at: i64,
    created_at: i64,
};

pub const New = struct {
    code_hash: [32]u8,
    user_code: []const u8,
    name: []const u8,
    scope: []const u8,
    expires_at: i64,
};

/// False when the user code is already taken by a waiting request.
pub fn insert(connection: *db.Db, new: New, now_ms: i64) db.Error!bool {
    std.debug.assert(new.user_code.len > 0);
    std.debug.assert(new.expires_at > now_ms);

    var statement = try connection.prepare(
        "INSERT INTO device_requests (code_hash, user_code, name, scope, state, expires_at, " ++
            "created_at) VALUES (?1, ?2, ?3, ?4, 'pending', ?5, ?6) " ++
            "ON CONFLICT DO NOTHING",
    );
    defer statement.finalize();

    try statement.bind_blob(1, &new.code_hash);
    try statement.bind_text(2, new.user_code);
    try statement.bind_text(3, new.name);
    try statement.bind_text(4, new.scope);
    try statement.bind_int(5, new.expires_at);
    try statement.bind_int(6, now_ms);
    try statement.exec();

    return connection.changes() == 1;
}

const columns_sql = "code_hash, user_code, name, scope, state, user_id, expires_at, created_at";

pub fn find_by_user_code(
    connection: *db.Db,
    arena: std.mem.Allocator,
    user_code: []const u8,
) db.Error!?Request {
    std.debug.assert(user_code.len > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    var select = try connection.prepare(
        "SELECT " ++ columns_sql ++ " FROM device_requests WHERE user_code = ?1",
    );
    defer select.finalize();

    try select.bind_text(1, user_code);

    if (!try select.step()) {
        return null;
    }

    return try select.read(Request, arena);
}

pub fn find_by_code_hash(
    connection: *db.Db,
    arena: std.mem.Allocator,
    code_hash: [32]u8,
) db.Error!?Request {
    std.debug.assert(code_hash.len == 32);
    std.debug.assert(connection.transaction_depth <= 8);

    var select = try connection.prepare(
        "SELECT " ++ columns_sql ++ " FROM device_requests WHERE code_hash = ?1",
    );
    defer select.finalize();

    try select.bind_blob(1, &code_hash);

    if (!try select.step()) {
        return null;
    }

    return try select.read(Request, arena);
}

pub const Decision = struct {
    user_code: []const u8,
    state: []const u8,
    scope: []const u8,
    user_id: []const u8,
};

/// A waiting request approved or denied by `user_id`. False when it no longer waits.
pub fn decide(connection: *db.Db, decision: Decision, now_ms: i64) db.Error!bool {
    std.debug.assert(decision.user_code.len > 0);
    std.debug.assert(decision.user_id.len > 0);

    var statement = try connection.prepare(
        "UPDATE device_requests SET state = ?1, scope = ?2, user_id = ?3 " ++
            "WHERE user_code = ?4 AND state = 'pending' AND expires_at > ?5",
    );
    defer statement.finalize();

    try statement.bind_text(1, decision.state);
    try statement.bind_text(2, decision.scope);
    try statement.bind_text(3, decision.user_id);
    try statement.bind_text(4, decision.user_code);
    try statement.bind_int(5, now_ms);
    try statement.exec();

    return connection.changes() == 1;
}

pub fn remove(connection: *db.Db, code_hash: [32]u8) db.Error!void {
    std.debug.assert(code_hash.len == 32);
    std.debug.assert(connection.transaction_depth <= 8);

    var statement = try connection.prepare("DELETE FROM device_requests WHERE code_hash = ?1");
    defer statement.finalize();

    try statement.bind_blob(1, &code_hash);
    try statement.exec();
}

/// Forgets requests past their time, whatever became of them.
pub fn cleanup(connection: *db.Db, now_ms: i64) db.Error!u32 {
    std.debug.assert(now_ms >= 0);
    std.debug.assert(cleanup_batch > 0);

    var statement = try connection.prepare(
        "DELETE FROM device_requests WHERE rowid IN " ++
            "(SELECT rowid FROM device_requests WHERE expires_at <= ?1 LIMIT " ++
            std.fmt.comptimePrint("{d}", .{cleanup_batch}) ++ ")",
    );
    defer statement.finalize();

    try statement.bind_int(1, now_ms);
    try statement.exec();

    return connection.changes();
}

test "a request waits, is decided once, and lapses" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const user_id = try @import("users.zig").insert(&fixture.connection, std.testing.io, arena, .{
        .email = "person@example.com",
        .display_name = "Person",
        .password_hash = "$argon2id$x",
        .roles = &.{"admin"},
        .now_ms = 0,
    });
    const hash = [_]u8{7} ** 32;
    const new: New = .{
        .code_hash = hash,
        .user_code = "BCDF-GHJK",
        .name = "laptop",
        .scope = "write",
        .expires_at = 10_000,
    };

    try std.testing.expect(try insert(&fixture.connection, new, 1_000));
    try std.testing.expect(!try insert(&fixture.connection, new, 1_000));

    const waiting = (try find_by_user_code(&fixture.connection, arena, "BCDF-GHJK")).?;
    try std.testing.expectEqualStrings("pending", waiting.state);

    const approve: Decision = .{
        .user_code = "BCDF-GHJK",
        .state = "approved",
        .scope = "drafts",
        .user_id = user_id,
    };
    try std.testing.expect(try decide(&fixture.connection, approve, 2_000));
    try std.testing.expect(!try decide(&fixture.connection, approve, 2_000));

    const approved = (try find_by_code_hash(&fixture.connection, arena, hash)).?;
    try std.testing.expectEqualStrings("drafts", approved.scope);
    try std.testing.expectEqualStrings(user_id, approved.user_id.?);

    try std.testing.expectEqual(@as(u32, 1), try cleanup(&fixture.connection, 10_000));
    try std.testing.expect(try find_by_code_hash(&fixture.connection, arena, hash) == null);
}
