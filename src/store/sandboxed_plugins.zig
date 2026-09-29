const std = @import("std");
const db = @import("../lib/db.zig");
const sandboxed_plugin = @import("../model/sandboxed_plugin.zig");

pub const Error = db.Error || error{NotFound};
pub const list_max: u32 = sandboxed_plugin.sandboxed_plugins_max;

/// One row of `plugins`. Field order is the column order of `select_row`.
pub const Row = struct {
    name: []const u8,
    version: []const u8,
    hash: []const u8,
    manifest: []const u8,
    /// Running: its operations and hooks are loaded. A plugin added and not yet enabled,
    /// or disabled, keeps its row and its grants and runs nothing.
    enabled: bool,
    granted: []const u8,
    denied: []const u8,
    content_access: []const u8,
    /// A newer module uploaded for it, waiting to be applied.
    next_version: ?[]const u8,
    next_hash: ?[]const u8,
    next_manifest: ?[]const u8,
    /// The version the last update replaced, kept to roll back to.
    previous_version: ?[]const u8,
    previous_hash: ?[]const u8,
    previous_manifest: ?[]const u8,
    installed_at: i64,
    updated_at: i64,
};

const select_row = "SELECT name, version, hash, manifest, enabled, granted, denied, " ++
    "content_access, next_version, next_hash, next_manifest, previous_version, " ++
    "previous_hash, previous_manifest, installed_at, updated_at FROM sandboxed_plugins";

pub fn get(connection: *db.Db, arena: std.mem.Allocator, name: []const u8) Error!?Row {
    std.debug.assert(name.len > 0);
    std.debug.assert(name.len <= sandboxed_plugin.name_len_max);

    var select = try connection.prepare(select_row ++ " WHERE name = ?1");
    defer select.finalize();

    try select.bind_text(1, name);

    if (!try select.step()) {
        return null;
    }

    return try select.read(Row, arena);
}

/// Every installed plugin, by name.
pub fn list(connection: *db.Db, arena: std.mem.Allocator) Error![]Row {
    std.debug.assert(list_max > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    var select = try connection.prepare(select_row ++ " ORDER BY name LIMIT ?1");
    defer select.finalize();

    try select.bind_int(1, list_max);

    var rows: std.ArrayList(Row) = .empty;

    while (try select.step()) {
        std.debug.assert(rows.items.len < list_max);
        rows.append(arena, try select.read(Row, arena)) catch return error.OutOfMemory;
    }

    return rows.items;
}

pub fn count(connection: *db.Db) Error!u32 {
    std.debug.assert(list_max > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    var select = try connection.prepare("SELECT COUNT(*) FROM sandboxed_plugins");
    defer select.finalize();

    std.debug.assert(try select.step());

    return @intCast(@max(0, select.read_int()));
}

/// Inserts a plugin, or replaces every column of the one by that name.
pub fn put(connection: *db.Db, row: Row) Error!void {
    std.debug.assert(row.name.len > 0);
    std.debug.assert(row.hash.len > 0);

    var statement = try connection.prepare(
        "INSERT INTO sandboxed_plugins (name, version, hash, manifest, enabled, granted, " ++
            "denied, content_access, next_version, next_hash, next_manifest, previous_version, " ++
            "previous_hash, previous_manifest, installed_at, updated_at) VALUES " ++
            "(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16) " ++
            "ON CONFLICT (name) DO UPDATE SET version = excluded.version, " ++
            "hash = excluded.hash, manifest = excluded.manifest, enabled = excluded.enabled, " ++
            "granted = excluded.granted, denied = excluded.denied, " ++
            "content_access = excluded.content_access, next_version = excluded.next_version, " ++
            "next_hash = excluded.next_hash, next_manifest = excluded.next_manifest, " ++
            "previous_version = excluded.previous_version, " ++
            "previous_hash = excluded.previous_hash, " ++
            "previous_manifest = excluded.previous_manifest, updated_at = excluded.updated_at",
    );
    defer statement.finalize();

    try statement.bind_text(1, row.name);
    try statement.bind_text(2, row.version);
    try statement.bind_text(3, row.hash);
    try statement.bind_text(4, row.manifest);
    try statement.bind_int(5, @intFromBool(row.enabled));
    try statement.bind_text(6, row.granted);
    try statement.bind_text(7, row.denied);
    try statement.bind_text(8, row.content_access);
    try statement.bind_optional_text(9, row.next_version);
    try statement.bind_optional_text(10, row.next_hash);
    try statement.bind_optional_text(11, row.next_manifest);
    try statement.bind_optional_text(12, row.previous_version);
    try statement.bind_optional_text(13, row.previous_hash);
    try statement.bind_optional_text(14, row.previous_manifest);
    try statement.bind_int(15, row.installed_at);
    try statement.bind_int(16, row.updated_at);
    try statement.exec();
}

pub fn delete(connection: *db.Db, name: []const u8) Error!void {
    std.debug.assert(name.len > 0);
    std.debug.assert(name.len <= sandboxed_plugin.name_len_max);

    var statement = try connection.prepare("DELETE FROM sandboxed_plugins WHERE name = ?1");
    defer statement.finalize();

    try statement.bind_text(1, name);
    try statement.exec();

    if (connection.changes() == 0) {
        return error.NotFound;
    }
}

test "put inserts then replaces, list sees it, delete removes it" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var row: Row = .{
        .name = "greeter",
        .version = "0.1.0",
        .hash = "aa",
        .manifest = "{}",
        .enabled = false,
        .granted = "[]",
        .denied = "[]",
        .content_access = "{\"scope\":\"public\"}",
        .next_version = null,
        .next_hash = null,
        .next_manifest = null,
        .previous_version = null,
        .previous_hash = null,
        .previous_manifest = null,
        .installed_at = 1,
        .updated_at = 1,
    };

    try put(&fixture.connection, row);
    row.next_hash = "bb";
    row.enabled = true;
    row.updated_at = 2;
    try put(&fixture.connection, row);

    const stored = (try get(&fixture.connection, arena, "greeter")).?;

    try std.testing.expectEqualStrings("bb", stored.next_hash.?);
    try std.testing.expect(stored.enabled);
    try std.testing.expect(stored.previous_hash == null);
    try std.testing.expectEqual(@as(i64, 1), stored.installed_at);
    try std.testing.expectEqual(@as(u32, 1), try count(&fixture.connection));
    try std.testing.expectEqual(@as(usize, 1), (try list(&fixture.connection, arena)).len);

    try delete(&fixture.connection, "greeter");
    try std.testing.expectError(error.NotFound, delete(&fixture.connection, "greeter"));
    try std.testing.expect(try get(&fixture.connection, arena, "greeter") == null);
}
