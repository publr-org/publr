const std = @import("std");
const db = @import("../lib/db.zig");
const model = @import("../model/identity.zig");

pub const provider_len_max = model.provider_len_max;
pub const id_len_max = model.id_len_max;
pub const per_user_max: u32 = 16;

pub const Row = struct {
    provider: []const u8,
    provider_id: []const u8,
    user_id: []const u8,
    /// The email as the provider last reported it, if it did.
    email: ?[]const u8,
    created_at: i64,
    last_used_at: i64,
};

pub const Insert = struct {
    provider: []const u8,
    provider_id: []const u8,
    user_id: []const u8,
    email: ?[]const u8,
    now_ms: i64,
};

const columns = "provider, provider_id, user_id, email, created_at, last_used_at FROM identities";

pub fn find(
    connection: *db.Db,
    arena: std.mem.Allocator,
    provider: []const u8,
    provider_id: []const u8,
) db.Error!?Row {
    std.debug.assert(provider.len > 0 and provider.len <= provider_len_max);
    std.debug.assert(provider_id.len > 0 and provider_id.len <= id_len_max);

    var select = try connection.prepare(
        "SELECT " ++ columns ++ " WHERE provider = ?1 AND provider_id = ?2",
    );
    defer select.finalize();

    try select.bind_text(1, provider);
    try select.bind_text(2, provider_id);

    if (!try select.step()) {
        return null;
    }

    return try select.read(Row, arena);
}

/// Links a provider's user to an account. A constraint error when the identity is linked
/// already: whether it is the same account is the caller's to know first.
pub fn insert(connection: *db.Db, row: Insert) db.Error!void {
    std.debug.assert(row.provider.len > 0 and row.provider.len <= provider_len_max);
    std.debug.assert(row.provider_id.len > 0 and row.provider_id.len <= id_len_max);
    std.debug.assert(row.user_id.len > 0);
    std.debug.assert(row.now_ms >= 0);

    var statement = try connection.prepare(
        "INSERT INTO identities " ++
            "(provider, provider_id, user_id, email, created_at, last_used_at) " ++
            "VALUES (?1, ?2, ?3, ?4, ?5, ?5)",
    );
    defer statement.finalize();

    try statement.bind_text(1, row.provider);
    try statement.bind_text(2, row.provider_id);
    try statement.bind_text(3, row.user_id);
    try statement.bind_optional_text(4, row.email);
    try statement.bind_int(5, row.now_ms);
    try statement.exec();

    std.debug.assert(connection.changes() == 1);
}

/// Notes a sign-in: when, and the email as the provider reports it now.
pub fn touch(
    connection: *db.Db,
    provider: []const u8,
    provider_id: []const u8,
    email: ?[]const u8,
    now_ms: i64,
) db.Error!void {
    std.debug.assert(provider.len > 0 and provider_id.len > 0);
    std.debug.assert(now_ms >= 0);

    var statement = try connection.prepare(
        "UPDATE identities SET last_used_at = ?1, email = ?2 " ++
            "WHERE provider = ?3 AND provider_id = ?4",
    );
    defer statement.finalize();

    try statement.bind_int(1, now_ms);
    try statement.bind_optional_text(2, email);
    try statement.bind_text(3, provider);
    try statement.bind_text(4, provider_id);
    try statement.exec();

    std.debug.assert(connection.changes() == 1);
}

/// The identities linked to an account, oldest first.
pub fn of_user(connection: *db.Db, arena: std.mem.Allocator, user_id: []const u8) db.Error![]Row {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(per_user_max > 0);

    var select = try connection.prepare(
        "SELECT " ++ columns ++ " WHERE user_id = ?1 ORDER BY created_at, provider LIMIT " ++
            std.fmt.comptimePrint("{d}", .{per_user_max}),
    );
    defer select.finalize();

    try select.bind_text(1, user_id);

    var rows: std.ArrayList(Row) = .empty;

    while (try select.step()) {
        std.debug.assert(rows.items.len < per_user_max);
        rows.append(arena, try select.read(Row, arena)) catch return error.OutOfMemory;
    }

    return rows.items;
}

pub fn count_of_user(connection: *db.Db, user_id: []const u8) db.Error!u32 {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    var select = try connection.prepare("SELECT count(*) FROM identities WHERE user_id = ?1");
    defer select.finalize();

    try select.bind_text(1, user_id);
    std.debug.assert(try select.step());

    return @intCast(select.read_int());
}

/// False when there was nothing to remove.
pub fn delete(connection: *db.Db, provider: []const u8, provider_id: []const u8) db.Error!bool {
    std.debug.assert(provider.len > 0 and provider_id.len > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    var statement = try connection.prepare(
        "DELETE FROM identities WHERE provider = ?1 AND provider_id = ?2",
    );
    defer statement.finalize();

    try statement.bind_text(1, provider);
    try statement.bind_text(2, provider_id);
    try statement.exec();

    return connection.changes() == 1;
}

test "an identity links once, is found by provider and id, and goes with its account" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;
    const users = @import("users.zig");
    const ada = try users.insert(connection, std.testing.io, arena, .{
        .email = "ada@example.com",
        .display_name = "Ada",
        .password_hash = null,
        .roles = &.{"editor"},
        .now_ms = 10,
    });

    try std.testing.expect((try find(connection, arena, "github", "1")) == null);
    try insert(connection, .{
        .provider = "github",
        .provider_id = "1",
        .user_id = ada,
        .email = null,
        .now_ms = 20,
    });
    try insert(connection, .{
        .provider = "google",
        .provider_id = "1",
        .user_id = ada,
        .email = "ada@example.com",
        .now_ms = 30,
    });

    const again: Insert = .{
        .provider = "github",
        .provider_id = "1",
        .user_id = ada,
        .email = null,
        .now_ms = 40,
    };

    try std.testing.expectError(error.Constraint, insert(connection, again));

    try touch(connection, "github", "1", "ada@github.example", 50);

    const found = (try find(connection, arena, "github", "1")).?;
    try std.testing.expectEqualStrings(ada, found.user_id);
    try std.testing.expectEqualStrings("ada@github.example", found.email.?);
    try std.testing.expectEqual(@as(i64, 20), found.created_at);
    try std.testing.expectEqual(@as(i64, 50), found.last_used_at);

    const linked = try of_user(connection, arena, ada);
    try std.testing.expectEqual(@as(usize, 2), linked.len);
    try std.testing.expectEqualStrings("github", linked[0].provider);
    try std.testing.expectEqualStrings("google", linked[1].provider);
    try std.testing.expectEqual(@as(u32, 2), try count_of_user(connection, ada));

    try std.testing.expect(try delete(connection, "google", "1"));
    try std.testing.expect(!try delete(connection, "google", "1"));
    try std.testing.expectEqual(@as(u32, 1), try count_of_user(connection, ada));

    try std.testing.expect(try users.delete(connection, ada));
    try std.testing.expect((try find(connection, arena, "github", "1")) == null);
}
