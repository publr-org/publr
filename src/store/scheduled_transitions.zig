//! The status transitions people scheduled (`scheduled_transitions`): one per record, made
//! by the worker once due, then removed.
const std = @import("std");
const db = @import("../lib/db.zig");

pub const Error = db.Error || error{OutOfMemory};

/// Transitions one pass makes: the rest wait for the next.
pub const take_max: u32 = 64;

pub const Transition = struct {
    record_id: []const u8,
    transition: []const u8,
    due_at: i64,
    scheduled_by: []const u8,
    scheduled_at: i64,
};

/// Schedules `transition`, replacing any the record had scheduled.
pub fn put(connection: *db.Db, transition: Transition) db.Error!void {
    std.debug.assert(transition.record_id.len > 0);
    std.debug.assert(transition.transition.len > 0);

    var insert = try connection.prepare(
        "INSERT INTO scheduled_transitions (record_id, transition, due_at, scheduled_by, " ++
            "scheduled_at) VALUES (?1, ?2, ?3, ?4, ?5) ON CONFLICT (record_id) DO UPDATE SET " ++
            "transition = excluded.transition, due_at = excluded.due_at, " ++
            "scheduled_by = excluded.scheduled_by, scheduled_at = excluded.scheduled_at",
    );
    defer insert.finalize();

    try insert.bind_text(1, transition.record_id);
    try insert.bind_text(2, transition.transition);
    try insert.bind_int(3, transition.due_at);
    try insert.bind_text(4, transition.scheduled_by);
    try insert.bind_int(5, transition.scheduled_at);
    try insert.exec();
}

/// The record's scheduled transition; null when it has none.
pub fn get(connection: *db.Db, arena: std.mem.Allocator, record_id: []const u8) Error!?Transition {
    std.debug.assert(record_id.len > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    var select = try connection.prepare(
        "SELECT record_id, transition, due_at, scheduled_by, scheduled_at " ++
            "FROM scheduled_transitions WHERE record_id = ?1",
    );
    defer select.finalize();

    try select.bind_text(1, record_id);

    if (!try select.step()) {
        return null;
    }

    return try select.read(Transition, arena);
}

/// Whether the record had a transition scheduled: it has none now.
pub fn remove(connection: *db.Db, record_id: []const u8) db.Error!bool {
    std.debug.assert(record_id.len > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    var delete = try connection.prepare("DELETE FROM scheduled_transitions WHERE record_id = ?1");
    defer delete.finalize();

    try delete.bind_text(1, record_id);
    try delete.exec();

    return connection.changes() > 0;
}

/// Made: removed, unless it was scheduled again meanwhile.
pub fn made(connection: *db.Db, transition: Transition) db.Error!void {
    std.debug.assert(transition.record_id.len > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    var delete = try connection.prepare(
        "DELETE FROM scheduled_transitions WHERE record_id = ?1 AND scheduled_at = ?2",
    );
    defer delete.finalize();

    try delete.bind_text(1, transition.record_id);
    try delete.bind_int(2, transition.scheduled_at);
    try delete.exec();
}

/// When the next scheduled transition is due; null when none is.
pub fn next_due(connection: *db.Db) db.Error!?i64 {
    std.debug.assert(connection.transaction_depth <= 8);
    std.debug.assert(take_max > 0);

    var select = try connection.prepare(
        "SELECT due_at FROM scheduled_transitions ORDER BY due_at LIMIT 1",
    );
    defer select.finalize();

    if (!try select.step()) {
        return null;
    }

    return select.read_int();
}

/// The transitions due by `now_ms`, soonest first, up to `max`.
pub fn due(
    connection: *db.Db,
    arena: std.mem.Allocator,
    now_ms: i64,
    max: u32,
) Error![]const Transition {
    std.debug.assert(max > 0 and max <= take_max);
    std.debug.assert(now_ms >= 0);

    var select = try connection.prepare(
        "SELECT record_id, transition, due_at, scheduled_by, scheduled_at " ++
            "FROM scheduled_transitions WHERE due_at <= ?1 ORDER BY due_at, record_id LIMIT ?2",
    );
    defer select.finalize();

    try select.bind_int(1, now_ms);
    try select.bind_int(2, max);

    var rows: std.ArrayList(Transition) = .empty;

    while (try select.step()) {
        std.debug.assert(rows.items.len < max);
        try rows.append(arena, try select.read(Transition, arena));
    }

    return rows.items;
}

test "scheduled transitions: one per record, found when due, removed" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const connection = &fixture.connection;

    try put(connection, .{
        .record_id = "r1",
        .transition = "publish",
        .due_at = 500,
        .scheduled_by = "u_1",
        .scheduled_at = 1,
    });
    try put(connection, .{
        .record_id = "r1",
        .transition = "archive",
        .due_at = 900,
        .scheduled_by = "u_1",
        .scheduled_at = 2,
    });

    try std.testing.expectEqualStrings("archive", (try get(connection, arena, "r1")).?.transition);
    try std.testing.expectEqual(0, (try due(connection, arena, 899, 8)).len);
    try std.testing.expectEqual(1, (try due(connection, arena, 900, 8)).len);
    try std.testing.expect(try remove(connection, "r1"));
    try std.testing.expect(!try remove(connection, "r1"));
    try std.testing.expectEqual(null, try get(connection, arena, "r1"));
}
