const std = @import("std");
const db = @import("../lib/db.zig");
const user_module = @import("users.zig");

pub const id_len: u32 = 24;
pub const secret_bytes: u32 = 32;
pub const secret_len: u32 = secret_bytes * 2;
pub const token_len: u32 = id_len + 1 + secret_len;
pub const lifetime_ms: i64 = 30 * 24 * 60 * 60 * 1000;
pub const per_user_max: u32 = 32;
pub const cleanup_batch: u32 = 256;

pub const Error = db.Error || error{ SessionNotFound, SessionExpired };

pub const Session = struct {
    id: []const u8,
    user_id: []const u8,
    expires_at: i64,
    created_at: i64,
};

pub const Created = struct {
    token: [token_len]u8,
    session: Session,

    pub fn token_text(created: *const Created) []const u8 {
        std.debug.assert(created.token[id_len] == '.');
        std.debug.assert(created.token.len == token_len);

        return &created.token;
    }
};

pub fn create(
    connection: *db.Db,
    io: std.Io,
    arena: std.mem.Allocator,
    user_id: []const u8,
    now_ms: i64,
) db.Error!Created {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(now_ms >= 0);

    var id_raw: [id_len / 2]u8 = undefined;
    var secret: [secret_bytes]u8 = undefined;
    io.random(&id_raw);
    io.random(&secret);

    var created: Created = undefined;
    created.token[0..id_len].* = std.fmt.bytesToHex(id_raw, .lower);
    created.token[id_len] = '.';
    created.token[id_len + 1 ..].* = std.fmt.bytesToHex(secret, .lower);

    var secret_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&secret, &secret_hash, .{});

    const id = arena.dupe(u8, created.token[0..id_len]) catch return error.OutOfMemory;
    const expires_at = now_ms + lifetime_ms;

    var statement = try connection.prepare(
        "INSERT INTO sessions (id, secret_hash, user_id, expires_at, created_at) " ++
            "VALUES (?1, ?2, ?3, ?4, ?5)",
    );
    defer statement.finalize();

    try statement.bind_text(1, id);
    try statement.bind_blob(2, &secret_hash);
    try statement.bind_text(3, user_id);
    try statement.bind_int(4, expires_at);
    try statement.bind_int(5, now_ms);
    try statement.exec();

    try evict_oldest(connection, user_id);

    created.session = .{
        .id = id,
        .user_id = user_id,
        .expires_at = expires_at,
        .created_at = now_ms,
    };

    return created;
}

pub fn validate(
    connection: *db.Db,
    arena: std.mem.Allocator,
    token: []const u8,
    now_ms: i64,
) Error!Session {
    std.debug.assert(now_ms >= 0);

    if (token.len != token_len or token[id_len] != '.') {
        return error.SessionNotFound;
    }

    const id = token[0..id_len];
    var secret: [secret_bytes]u8 = undefined;
    _ = std.fmt.hexToBytes(&secret, token[id_len + 1 ..]) catch return error.SessionNotFound;

    var provided_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&secret, &provided_hash, .{});

    var session = try lookup(connection, arena, id, provided_hash);

    if (session.expires_at <= now_ms) {
        try destroy(connection, session.id);

        return error.SessionExpired;
    }

    if (session.expires_at - now_ms < lifetime_ms / 2) {
        session.expires_at = now_ms + lifetime_ms;
        try extend(connection, session.id, session.expires_at);
    }

    std.debug.assert(session.expires_at > now_ms);

    return session;
}

fn lookup(
    connection: *db.Db,
    arena: std.mem.Allocator,
    id: []const u8,
    provided_hash: [32]u8,
) Error!Session {
    std.debug.assert(id.len == id_len);
    std.debug.assert(provided_hash.len == 32);

    var select = try connection.prepare(
        "SELECT secret_hash, user_id, expires_at, created_at FROM sessions WHERE id = ?1",
    );
    defer select.finalize();

    try select.bind_text(1, id);

    if (!try select.step()) {
        return error.SessionNotFound;
    }

    const Columns = struct {
        secret_hash: db.Blob,
        user_id: []const u8,
        expires_at: i64,
        created_at: i64,
    };
    const columns = try select.read(Columns, arena);
    const stored_hash = columns.secret_hash.bytes;

    if (stored_hash.len != 32) {
        return error.SessionNotFound;
    }

    if (!std.crypto.timing_safe.eql([32]u8, stored_hash[0..32].*, provided_hash)) {
        return error.SessionNotFound;
    }

    return .{
        .id = try arena.dupe(u8, id),
        .user_id = columns.user_id,
        .expires_at = columns.expires_at,
        .created_at = columns.created_at,
    };
}

pub fn destroy(connection: *db.Db, id: []const u8) db.Error!void {
    std.debug.assert(id.len == id_len);
    std.debug.assert(connection.transaction_depth <= 8);

    var statement = try connection.prepare("DELETE FROM sessions WHERE id = ?1");
    defer statement.finalize();

    try statement.bind_text(1, id);
    try statement.exec();
}

pub fn destroy_all(connection: *db.Db, user_id: []const u8) db.Error!u32 {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    var statement = try connection.prepare("DELETE FROM sessions WHERE user_id = ?1");
    defer statement.finalize();

    try statement.bind_text(1, user_id);
    try statement.exec();

    return connection.changes();
}

pub fn cleanup(connection: *db.Db, now_ms: i64) db.Error!u32 {
    std.debug.assert(now_ms >= 0);
    std.debug.assert(cleanup_batch > 0);

    var statement = try connection.prepare(
        "DELETE FROM sessions WHERE rowid IN " ++
            "(SELECT rowid FROM sessions WHERE expires_at <= ?1 LIMIT " ++
            std.fmt.comptimePrint("{d}", .{cleanup_batch}) ++ ")",
    );
    defer statement.finalize();

    try statement.bind_int(1, now_ms);
    try statement.exec();

    return connection.changes();
}

fn extend(connection: *db.Db, id: []const u8, expires_at: i64) db.Error!void {
    std.debug.assert(id.len == id_len);
    std.debug.assert(expires_at > 0);

    var statement = try connection.prepare("UPDATE sessions SET expires_at = ?1 WHERE id = ?2");
    defer statement.finalize();

    try statement.bind_int(1, expires_at);
    try statement.bind_text(2, id);
    try statement.exec();
}

fn evict_oldest(connection: *db.Db, user_id: []const u8) db.Error!void {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(per_user_max > 0);

    var statement = try connection.prepare(
        "DELETE FROM sessions WHERE user_id = ?1 AND id NOT IN " ++
            "(SELECT id FROM sessions WHERE user_id = ?1 " ++
            "ORDER BY created_at DESC, id DESC LIMIT " ++
            std.fmt.comptimePrint("{d}", .{per_user_max}) ++ ")",
    );
    defer statement.finalize();

    try statement.bind_text(1, user_id);
    try statement.exec();
}

fn seed_user(
    fixture: *db.testing.Fixture,
    arena: std.mem.Allocator,
    email: []const u8,
) ![]const u8 {
    std.debug.assert(email.len > 0);
    std.debug.assert(fixture.connection.transaction_depth == 0);

    return user_module.insert(&fixture.connection, std.testing.io, arena, .{
        .email = email,
        .display_name = "Test",
        .password_hash = "$argon2id$x",
        .roles = &.{"admin"},
        .now_ms = 0,
    });
}

test "create, validate, sliding expiry, expiry, destroy" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const user_id = try seed_user(&fixture, arena, "a@example.com");

    const created = try create(&fixture.connection, std.testing.io, arena, user_id, 1_000);
    const token = created.token_text();
    try std.testing.expectEqual(@as(usize, token_len), token.len);

    const early = try validate(&fixture.connection, arena, token, 2_000);
    try std.testing.expectEqualStrings(user_id, early.user_id);
    try std.testing.expectEqual(@as(i64, 1_000 + lifetime_ms), early.expires_at);

    const late_ms = 1_000 + lifetime_ms / 2 + 1;
    const slid = try validate(&fixture.connection, arena, token, late_ms);
    try std.testing.expectEqual(late_ms + lifetime_ms, slid.expires_at);

    const expired = validate(&fixture.connection, arena, token, late_ms + lifetime_ms);
    try std.testing.expectError(error.SessionExpired, expired);
    const before_creation = validate(&fixture.connection, arena, token, 0);
    try std.testing.expectError(error.SessionNotFound, before_creation);
}

test "wrong secret, malformed token, destroy and destroy_all" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const user_id = try seed_user(&fixture, arena, "b@example.com");

    const first = try create(&fixture.connection, std.testing.io, arena, user_id, 10);
    const second = try create(&fixture.connection, std.testing.io, arena, user_id, 20);

    var forged: [token_len]u8 = first.token;
    forged[token_len - 1] = if (forged[token_len - 1] == 'a') 'b' else 'a';
    const forged_result = validate(&fixture.connection, arena, &forged, 30);
    const malformed = validate(&fixture.connection, arena, "nope", 30);
    try std.testing.expectError(error.SessionNotFound, forged_result);
    try std.testing.expectError(error.SessionNotFound, malformed);

    try destroy(&fixture.connection, first.session.id);
    const gone = validate(&fixture.connection, arena, first.token_text(), 30);
    try std.testing.expectError(error.SessionNotFound, gone);
    _ = try validate(&fixture.connection, arena, second.token_text(), 30);

    try std.testing.expectEqual(@as(u32, 1), try destroy_all(&fixture.connection, user_id));
}

test "per-user cap evicts the oldest; cleanup removes expired in batches" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const user_id = try seed_user(&fixture, arena, "c@example.com");

    const oldest = try create(&fixture.connection, std.testing.io, arena, user_id, 1);
    var index: u32 = 0;

    while (index < per_user_max) : (index += 1) {
        _ = try create(&fixture.connection, std.testing.io, arena, user_id, 2 + index);
    }

    const evicted = validate(&fixture.connection, arena, oldest.token_text(), 100);
    try std.testing.expectError(error.SessionNotFound, evicted);

    try std.testing.expectEqual(@as(u32, 0), try cleanup(&fixture.connection, 100));
    try std.testing.expectEqual(per_user_max, try cleanup(&fixture.connection, 100 + lifetime_ms));
}
