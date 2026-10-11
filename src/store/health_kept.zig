//! The `health_kept` table: the broken references Site Health was told to leave as they are.

const std = @import("std");
const db = @import("../lib/db.zig");

pub const Kept = struct {
    target: []const u8,
    app: []const u8,
    reason: []const u8,
    holders: i64,
};

/// The case kept as it stands now, over any earlier keep of it.
pub fn put(connection: *db.Db, kept: Kept, now_ms: i64) db.Error!void {
    std.debug.assert(kept.target.len > 0);
    std.debug.assert(kept.holders > 0);

    var statement = try connection.prepare(
        "INSERT INTO health_kept (target, app, reason, holders, kept_at) " ++
            "VALUES (?1, ?2, ?3, ?4, ?5) ON CONFLICT (target, app) DO UPDATE SET " ++
            "reason = excluded.reason, holders = excluded.holders, kept_at = excluded.kept_at",
    );
    defer statement.finalize();

    try statement.bind_text(1, kept.target);
    try statement.bind_text(2, kept.app);
    try statement.bind_text(3, kept.reason);
    try statement.bind_int(4, kept.holders);
    try statement.bind_int(5, now_ms);
    try statement.exec();
}

/// The keep of the case at `target` for `app`; null when it was not kept.
pub fn find(
    connection: *db.Db,
    arena: std.mem.Allocator,
    target: []const u8,
    app: []const u8,
) db.Error!?Kept {
    std.debug.assert(target.len > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    var select = try connection.prepare(
        "SELECT target, app, reason, holders FROM health_kept WHERE target = ?1 AND app = ?2",
    );
    defer select.finalize();

    try select.bind_text(1, target);
    try select.bind_text(2, app);

    if (!try select.step()) {
        return null;
    }

    return try select.read(Kept, arena);
}

test "a kept case is stored once, the latest keep over the earlier one" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;

    try put(connection, .{
        .target = "a1",
        .app = "www",
        .reason = "not_shared",
        .holders = 2,
    }, 1_000);
    try put(connection, .{
        .target = "a1",
        .app = "www",
        .reason = "deleted",
        .holders = 3,
    }, 2_000);

    const row = (try find(connection, arena, "a1", "www")).?;
    try std.testing.expectEqualStrings("deleted", row.reason);
    try std.testing.expectEqual(3, row.holders);
    try std.testing.expectEqual(null, try find(connection, arena, "a1", "shop"));
}
