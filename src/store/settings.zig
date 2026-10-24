const std = @import("std");
const db = @import("../lib/db.zig");

pub const key_len_max: u32 = 128;
pub const value_len_max: u32 = 64 << 10;

pub fn get(connection: *db.Db, arena: std.mem.Allocator, key: []const u8) db.Error!?[]const u8 {
    std.debug.assert(key.len > 0);
    std.debug.assert(key.len <= key_len_max);

    var select = try connection.prepare("SELECT value FROM settings WHERE key = ?1");
    defer select.finalize();

    try select.bind_text(1, key);

    if (!try select.step()) {
        return null;
    }

    const Found = struct {
        value: []const u8,
    };
    return (try select.read(Found, arena)).value;
}

pub fn set(connection: *db.Db, key: []const u8, value: []const u8, now_ms: i64) db.Error!void {
    std.debug.assert(key.len > 0 and key.len <= key_len_max);
    std.debug.assert(value.len <= value_len_max);

    var upsert = try connection.prepare(
        "INSERT INTO settings (key, value, updated_at) VALUES (?1, ?2, ?3) " ++
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value, " ++
            "updated_at = excluded.updated_at",
    );
    defer upsert.finalize();

    try upsert.bind_text(1, key);
    try upsert.bind_text(2, value);
    try upsert.bind_int(3, now_ms);
    try upsert.exec();
}

/// The values of every setting whose key starts with `prefix`, at most `under_max`.
pub fn values_under(
    connection: *db.Db,
    arena: std.mem.Allocator,
    prefix: []const u8,
) db.Error![]const []const u8 {
    std.debug.assert(prefix.len > 0 and prefix.len < key_len_max);
    std.debug.assert(std.mem.indexOfAny(u8, prefix, "%_") == null);

    var select = try connection.prepare(
        "SELECT value FROM settings WHERE substr(key, 1, length(?1)) = ?1 ORDER BY key LIMIT ?2",
    );
    defer select.finalize();

    try select.bind_text(1, prefix);
    try select.bind_int(2, under_max);

    var found: std.ArrayList([]const u8) = .empty;

    while (try select.step()) {
        const Found = struct {
            value: []const u8,
        };

        try found.append(arena, (try select.read(Found, arena)).value);
    }

    return found.items;
}

pub const under_max: u32 = 1024;

pub fn delete(connection: *db.Db, key: []const u8) db.Error!void {
    std.debug.assert(key.len > 0 and key.len <= key_len_max);
    var statement = try connection.prepare("DELETE FROM settings WHERE key = ?1");
    defer statement.finalize();
    try statement.bind_text(1, key);
    try statement.exec();
}

test "get returns null until set; set upserts" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect((try get(&fixture.connection, arena, "a")) == null);
    try set(&fixture.connection, "a", "1", 10);
    try std.testing.expectEqualStrings("1", (try get(&fixture.connection, arena, "a")).?);
    try set(&fixture.connection, "a", "2", 20);
    try std.testing.expectEqualStrings("2", (try get(&fixture.connection, arena, "a")).?);
}
