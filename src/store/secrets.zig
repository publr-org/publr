const std = @import("std");
const db = @import("../lib/db.zig");
const secrets = @import("../model/secrets.zig");

/// Secrets kept, at most.
pub const listed_max: u32 = 256;

/// One row of `secrets`, its value still sealed. Field order is the column order of
/// `select_secret`.
pub const Secret = struct {
    name: []const u8,
    sealed: db.Blob,
    updated_at: i64,
};

const select_secret = "SELECT name, sealed, updated_at FROM secrets";

pub fn get(connection: *db.Db, arena: std.mem.Allocator, name: []const u8) db.Error!?Secret {
    std.debug.assert(secrets.valid_name(name));
    std.debug.assert(listed_max > 0);

    var select = try connection.prepare(select_secret ++ " WHERE name = ?1");
    defer select.finalize();

    try select.bind_text(1, name);

    if (!try select.step()) {
        return null;
    }

    return try select.read(Secret, arena);
}

/// A secret as a list names it: never its value.
pub const Named = struct {
    name: []const u8,
    updated_at: i64,
};

/// The secrets kept, by name, `limit` of them from `offset`.
pub fn names_page(
    connection: *db.Db,
    arena: std.mem.Allocator,
    offset: u32,
    limit: u32,
) db.Error![]Named {
    std.debug.assert(limit > 0 and limit <= listed_max);
    std.debug.assert(connection.transaction_depth <= 8);

    var select = try connection.prepare(
        "SELECT name, updated_at FROM secrets ORDER BY name LIMIT ?1 OFFSET ?2",
    );
    defer select.finalize();

    try select.bind_int(1, limit);
    try select.bind_int(2, offset);

    var rows: std.ArrayList(Named) = .empty;

    while (try select.step()) {
        std.debug.assert(rows.items.len < limit);
        rows.append(arena, try select.read(Named, arena)) catch return error.OutOfMemory;
    }

    return rows.items;
}

pub fn count(connection: *db.Db) db.Error!u32 {
    std.debug.assert(connection.transaction_depth <= 8);

    var select = try connection.prepare("SELECT count(*) FROM secrets");
    defer select.finalize();

    std.debug.assert(try select.step());

    return @intCast(select.read_int());
}

/// Keeps `sealed` under `name`, replacing what was there.
pub fn put(connection: *db.Db, name: []const u8, sealed: []const u8, now_ms: i64) db.Error!void {
    std.debug.assert(secrets.valid_name(name));
    std.debug.assert(sealed.len >= secrets.sealed_overhead);

    var statement = try connection.prepare(
        "INSERT INTO secrets (name, sealed, updated_at) VALUES (?1, ?2, ?3) " ++
            "ON CONFLICT(name) DO UPDATE SET sealed = ?2, updated_at = ?3",
    );
    defer statement.finalize();

    try statement.bind_text(1, name);
    try statement.bind_blob(2, sealed);
    try statement.bind_int(3, now_ms);
    try statement.exec();
}

/// Forgets a secret. False when none was kept under `name`.
pub fn delete(connection: *db.Db, name: []const u8) db.Error!bool {
    std.debug.assert(secrets.valid_name(name));
    std.debug.assert(name.len <= secrets.name_len_max);

    var statement = try connection.prepare("DELETE FROM secrets WHERE name = ?1");
    defer statement.finalize();

    try statement.bind_text(1, name);
    try statement.exec();

    return connection.changes() == 1;
}

/// The database's file, absolute; empty for one in memory. The project's key lives beside it.
pub fn database_path(connection: *db.Db, arena: std.mem.Allocator) db.Error![]const u8 {
    std.debug.assert(listed_max > 0);
    std.debug.assert(connection.transaction_depth >= 0);

    var select = try connection.prepare(
        "SELECT file FROM pragma_database_list WHERE name = 'main'",
    );
    defer select.finalize();

    if (!try select.step()) {
        return "";
    }

    const Row = struct {
        file: []const u8,
    };

    return (try select.read(Row, arena)).file;
}

test "a secret is kept sealed, replaced, listed by name and forgotten" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;
    const sealed = [_]u8{7} ** (secrets.sealed_overhead + 4);

    try put(connection, "B_KEY", &sealed, 1);
    try put(connection, "A_KEY", &sealed, 2);
    try put(connection, "A_KEY", &sealed, 3);

    const rows = try names_page(connection, arena, 0, 10);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("A_KEY", rows[0].name);
    try std.testing.expectEqual(@as(i64, 3), rows[0].updated_at);
    try std.testing.expectEqual(2, try count(connection));
    try std.testing.expectEqualStrings("B_KEY", (try names_page(connection, arena, 1, 10))[0].name);
    const found = (try get(connection, arena, "B_KEY")).?;
    try std.testing.expectEqualSlices(u8, &sealed, found.sealed.bytes);
    try std.testing.expect(try delete(connection, "B_KEY"));
    try std.testing.expect(!try delete(connection, "B_KEY"));
    try std.testing.expect(try get(connection, arena, "B_KEY") == null);
    try std.testing.expectEqualStrings("", try database_path(connection, arena));
}
