const std = @import("std");
const db = @import("../lib/db.zig");
const user_module = @import("users.zig");

pub const id_len: u32 = 24;
pub const secret_bytes: u32 = 32;
pub const secret_len: u32 = secret_bytes * 2;
pub const token_len: u32 = id_len + 1 + secret_len;
/// How stale `last_used_at` may get before a request writes it again: a device making a
/// request a second does not make a write a second.
pub const touch_interval_ms: i64 = std.time.ms_per_min;
pub const listed_max: u32 = 256;

pub const Error = db.Error || error{DeviceNotFound};

pub const Device = struct {
    id: []const u8,
    user_id: []const u8,
    name: []const u8,
    scope: []const u8,
    created_at: i64,
    last_used_at: i64,
    revoked_at: ?i64 = null,
};

pub const Created = struct {
    token: [token_len]u8,
    device: Device,

    pub fn token_text(created: *const Created) []const u8 {
        std.debug.assert(created.token[id_len] == '.');
        std.debug.assert(created.token.len == token_len);

        return &created.token;
    }
};

pub const New = struct { user_id: []const u8, name: []const u8, scope: []const u8 };

pub fn create(
    connection: *db.Db,
    io: std.Io,
    arena: std.mem.Allocator,
    new: New,
    now_ms: i64,
) db.Error!Created {
    std.debug.assert(new.user_id.len > 0);
    std.debug.assert(new.name.len > 0);

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

    var statement = try connection.prepare(
        "INSERT INTO devices (id, secret_hash, user_id, name, scope, created_at, " ++
            "last_used_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)",
    );
    defer statement.finalize();

    try statement.bind_text(1, id);
    try statement.bind_blob(2, &secret_hash);
    try statement.bind_text(3, new.user_id);
    try statement.bind_text(4, new.name);
    try statement.bind_text(5, new.scope);
    try statement.bind_int(6, now_ms);
    try statement.exec();

    created.device = .{
        .id = id,
        .user_id = new.user_id,
        .name = new.name,
        .scope = new.scope,
        .created_at = now_ms,
        .last_used_at = now_ms,
    };

    return created;
}

/// The device a token belongs to, unless it was revoked; its use noted, to the minute.
pub fn validate(
    connection: *db.Db,
    arena: std.mem.Allocator,
    token: []const u8,
    now_ms: i64,
) Error!Device {
    std.debug.assert(now_ms >= 0);

    if (token.len != token_len or token[id_len] != '.') {
        return error.DeviceNotFound;
    }

    var secret: [secret_bytes]u8 = undefined;
    _ = std.fmt.hexToBytes(&secret, token[id_len + 1 ..]) catch return error.DeviceNotFound;

    var provided_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&secret, &provided_hash, .{});

    var device = try lookup(connection, arena, token[0..id_len], provided_hash);

    if (device.revoked_at != null) {
        return error.DeviceNotFound;
    }

    if (now_ms - device.last_used_at >= touch_interval_ms) {
        try touch(connection, device.id, now_ms);
        device.last_used_at = now_ms;
    }

    std.debug.assert(device.last_used_at <= @max(now_ms, device.created_at));

    return device;
}

const columns_sql = "id, user_id, name, scope, created_at, last_used_at, revoked_at";

fn lookup(
    connection: *db.Db,
    arena: std.mem.Allocator,
    id: []const u8,
    provided_hash: [32]u8,
) Error!Device {
    std.debug.assert(id.len == id_len);
    std.debug.assert(provided_hash.len == 32);

    var select = try connection.prepare(
        "SELECT secret_hash, " ++ columns_sql ++ " FROM devices WHERE id = ?1",
    );
    defer select.finalize();

    try select.bind_text(1, id);

    if (!try select.step()) {
        return error.DeviceNotFound;
    }

    const Row = struct {
        secret_hash: db.Blob,
        id: []const u8,
        user_id: []const u8,
        name: []const u8,
        scope: []const u8,
        created_at: i64,
        last_used_at: i64,
        revoked_at: ?i64,
    };
    const row = try select.read(Row, arena);
    const stored_hash = row.secret_hash.bytes;

    if (stored_hash.len != 32) {
        return error.DeviceNotFound;
    }

    if (!std.crypto.timing_safe.eql([32]u8, stored_hash[0..32].*, provided_hash)) {
        return error.DeviceNotFound;
    }

    return .{
        .id = row.id,
        .user_id = row.user_id,
        .name = row.name,
        .scope = row.scope,
        .created_at = row.created_at,
        .last_used_at = row.last_used_at,
        .revoked_at = row.revoked_at,
    };
}

fn touch(connection: *db.Db, id: []const u8, now_ms: i64) db.Error!void {
    std.debug.assert(id.len == id_len);
    std.debug.assert(now_ms >= 0);

    var statement = try connection.prepare("UPDATE devices SET last_used_at = ?1 WHERE id = ?2");
    defer statement.finalize();

    try statement.bind_int(1, now_ms);
    try statement.bind_text(2, id);
    try statement.exec();
}

/// One device by id, revoked or not.
pub fn find(connection: *db.Db, arena: std.mem.Allocator, id: []const u8) db.Error!?Device {
    std.debug.assert(id.len > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    var select = try connection.prepare("SELECT " ++ columns_sql ++ " FROM devices WHERE id = ?1");
    defer select.finalize();

    try select.bind_text(1, id);

    if (!try select.step()) {
        return null;
    }

    return try select.read(Device, arena);
}

/// The devices that still work, newest first: one account's, or everyone's for null.
pub fn list(
    connection: *db.Db,
    arena: std.mem.Allocator,
    user_id: ?[]const u8,
) db.Error![]const Device {
    std.debug.assert(user_id == null or user_id.?.len > 0);
    std.debug.assert(listed_max > 0);

    var select = try connection.prepare(
        "SELECT " ++ columns_sql ++ " FROM devices " ++
            "WHERE revoked_at IS NULL AND (?1 IS NULL OR user_id = ?1) " ++
            "ORDER BY created_at DESC, id DESC LIMIT " ++
            std.fmt.comptimePrint("{d}", .{listed_max}),
    );
    defer select.finalize();

    try select.bind_optional_text(1, user_id);

    var found: std.ArrayList(Device) = .empty;

    while (try select.step()) {
        found.append(arena, try select.read(Device, arena)) catch return error.OutOfMemory;
    }

    std.debug.assert(found.items.len <= listed_max);

    return found.items;
}

/// Stops a device working. False when it was unknown or already revoked.
pub fn revoke(connection: *db.Db, id: []const u8, now_ms: i64) db.Error!bool {
    std.debug.assert(id.len > 0);
    std.debug.assert(now_ms >= 0);

    var statement = try connection.prepare(
        "UPDATE devices SET revoked_at = ?1 WHERE id = ?2 AND revoked_at IS NULL",
    );
    defer statement.finalize();

    try statement.bind_int(1, now_ms);
    try statement.bind_text(2, id);
    try statement.exec();

    return connection.changes() == 1;
}

fn seed_user(fixture: *db.testing.Fixture, arena: std.mem.Allocator) ![]const u8 {
    std.debug.assert(fixture.connection.transaction_depth == 0);

    return user_module.insert(&fixture.connection, std.testing.io, arena, .{
        .email = "agent@example.com",
        .display_name = "Test",
        .password_hash = "$argon2id$x",
        .roles = &.{"admin"},
        .now_ms = 0,
    });
}

test "create, validate, touch to the minute, revoke" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const user_id = try seed_user(&fixture, arena);
    const new: New = .{ .user_id = user_id, .name = "laptop", .scope = "drafts" };

    const created = try create(&fixture.connection, std.testing.io, arena, new, 1_000);
    const token = created.token_text();

    const early = try validate(&fixture.connection, arena, token, 2_000);
    try std.testing.expectEqualStrings("drafts", early.scope);
    try std.testing.expectEqual(@as(i64, 1_000), early.last_used_at);

    const later = try validate(&fixture.connection, arena, token, 1_000 + touch_interval_ms);
    try std.testing.expectEqual(1_000 + touch_interval_ms, later.last_used_at);

    var forged: [token_len]u8 = created.token;
    forged[token_len - 1] = if (forged[token_len - 1] == 'a') 'b' else 'a';
    const forged_result = validate(&fixture.connection, arena, &forged, 3_000);
    try std.testing.expectError(error.DeviceNotFound, forged_result);
    try std.testing.expectError(error.DeviceNotFound, validate(&fixture.connection, arena, "x", 0));

    try std.testing.expectEqual(@as(usize, 1), (try list(&fixture.connection, arena, null)).len);
    try std.testing.expect(try revoke(&fixture.connection, created.device.id, 4_000));
    try std.testing.expect(!try revoke(&fixture.connection, created.device.id, 5_000));
    const revoked = validate(&fixture.connection, arena, token, 6_000);
    try std.testing.expectError(error.DeviceNotFound, revoked);
    try std.testing.expectEqual(@as(usize, 0), (try list(&fixture.connection, arena, user_id)).len);

    const kept = (try find(&fixture.connection, arena, created.device.id)).?;
    try std.testing.expectEqualStrings("laptop", kept.name);
    try std.testing.expectEqual(@as(?i64, 4_000), kept.revoked_at);
}
