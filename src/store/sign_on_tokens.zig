//! Sign-on tokens already redeemed, kept until they expire: a token works once.

const std = @import("std");
const db = @import("../lib/db.zig");

pub const id_len_max: u32 = 64;
pub const cleanup_batch: u32 = 256;

/// Marks the token used. False when it already was: a replay.
pub fn claim(connection: *db.Db, id: []const u8, expires_at: i64) db.Error!bool {
    std.debug.assert(id.len > 0 and id.len <= id_len_max);
    std.debug.assert(expires_at > 0);

    var statement = try connection.prepare(
        "INSERT INTO sign_on_tokens (id, expires_at) VALUES (?1, ?2) ON CONFLICT (id) DO NOTHING",
    );
    defer statement.finalize();

    try statement.bind_text(1, id);
    try statement.bind_int(2, expires_at);
    try statement.exec();

    return connection.changes() == 1;
}

/// Forgets tokens past their expiry: an expired one is refused by its own date.
pub fn cleanup(connection: *db.Db, now_ms: i64) db.Error!u32 {
    std.debug.assert(now_ms >= 0);
    std.debug.assert(cleanup_batch > 0);

    var statement = try connection.prepare(
        "DELETE FROM sign_on_tokens WHERE rowid IN " ++
            "(SELECT rowid FROM sign_on_tokens WHERE expires_at <= ?1 LIMIT " ++
            std.fmt.comptimePrint("{d}", .{cleanup_batch}) ++ ")",
    );
    defer statement.finalize();

    try statement.bind_int(1, now_ms);
    try statement.exec();

    return connection.changes();
}

test "a token is claimed once" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    try std.testing.expect(try claim(&fixture.connection, "abc", 2_000));
    try std.testing.expect(!try claim(&fixture.connection, "abc", 2_000));
    try std.testing.expectEqual(@as(u32, 1), try cleanup(&fixture.connection, 3_000));
    try std.testing.expect(try claim(&fixture.connection, "abc", 5_000));
}
