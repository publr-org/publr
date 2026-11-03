//! What people scheduled for a record (`scheduled_changes`): any number each, a transition
//! (`publish`, `archive`) or, for a live record, its changes published (`publish` with the
//! fields it changed, `changes`, and what it holds back then). Made by the worker once due,
//! then removed; one refused stays, failed, with why.
const std = @import("std");
const db = @import("../lib/db.zig");

pub const Error = db.Error || error{OutOfMemory};

/// Entries one pass makes: the rest wait for the next.
pub const take_max: u32 = 64;
/// Entries one record keeps at most.
pub const record_max: u32 = 256;

pub const Entry = struct {
    id: i64 = 0,
    record_id: []const u8,
    transition: []const u8,
    /// The fields it publishes, a JSON object of each key and its value (null: emptied);
    /// empty for a transition.
    changes: []const u8 = "",
    /// What the record holds back once it is made (`model/dimension/live.zig`); null leaves
    /// what it holds back as it is.
    held_back: ?[]const u8 = null,
    /// The one it builds on; null for what is live.
    base_id: ?i64 = null,
    due_at: i64,
    scheduled_by: []const u8,
    scheduled_at: i64,
    /// `waiting`, `failed` with `problem` saying why, or `draft`: edits made on top of its
    /// base, not scheduled yet.
    state: []const u8 = "waiting",
    problem: []const u8 = "",
};

const columns = "id, record_id, transition, changes, held_back, base_id, due_at, " ++
    "scheduled_by, scheduled_at, state, problem";

/// A base: the entry's id, or null for what is live.
fn bind_base(statement: anytype, index: u31, base: ?i64) db.Error!void {
    std.debug.assert(index > 0);

    if (base) |id| {
        std.debug.assert(id > 0);

        return statement.bind_int(index, id);
    }

    return statement.bind_null(index);
}

/// Kept; answers its id.
pub fn add(connection: *db.Db, entry: Entry) db.Error!i64 {
    std.debug.assert(entry.record_id.len > 0);
    std.debug.assert(entry.transition.len > 0);

    var insert = try connection.prepare(
        "INSERT INTO scheduled_changes (record_id, transition, changes, held_back, base_id, " ++
            "due_at, scheduled_by, scheduled_at, state) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, " ++
            "?8, ?9) RETURNING id",
    );
    defer insert.finalize();

    try insert.bind_text(1, entry.record_id);
    try insert.bind_text(2, entry.transition);
    try insert.bind_text(3, entry.changes);
    try insert.bind_optional_text(4, entry.held_back);
    try bind_base(&insert, 5, entry.base_id);
    try insert.bind_int(6, entry.due_at);
    try insert.bind_text(7, entry.scheduled_by);
    try insert.bind_int(8, entry.scheduled_at);
    try insert.bind_text(9, entry.state);

    if (!try insert.step()) {
        return error.Sqlite;
    }

    return insert.read_int();
}

/// How many the record has scheduled, failed ones included.
pub fn count(connection: *db.Db, record_id: []const u8) db.Error!u32 {
    std.debug.assert(record_id.len > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    var select = try connection.prepare(
        "SELECT count(*) FROM scheduled_changes WHERE record_id = ?1",
    );
    defer select.finalize();

    try select.bind_text(1, record_id);

    if (!try select.step()) {
        return 0;
    }

    return @intCast(select.read_int());
}

/// Everything the record has scheduled, soonest first.
pub fn of_record(
    connection: *db.Db,
    arena: std.mem.Allocator,
    record_id: []const u8,
) Error![]const Entry {
    std.debug.assert(record_id.len > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    var select = try connection.prepare(
        "SELECT " ++ columns ++ " FROM scheduled_changes WHERE record_id = ?1 " ++
            "ORDER BY due_at, id LIMIT ?2",
    );
    defer select.finalize();

    try select.bind_text(1, record_id);
    try select.bind_int(2, record_max);

    var rows: std.ArrayList(Entry) = .empty;

    while (try select.step()) {
        std.debug.assert(rows.items.len < record_max);
        try rows.append(arena, try select.read(Entry, arena));
    }

    return rows.items;
}

/// The record's entry `id`; null when it has none.
pub fn get(
    connection: *db.Db,
    arena: std.mem.Allocator,
    record_id: []const u8,
    id: i64,
) Error!?Entry {
    std.debug.assert(record_id.len > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    var select = try connection.prepare(
        "SELECT " ++ columns ++ " FROM scheduled_changes WHERE record_id = ?1 AND id = ?2",
    );
    defer select.finalize();

    try select.bind_text(1, record_id);
    try select.bind_int(2, id);

    if (!try select.step()) {
        return null;
    }

    return try select.read(Entry, arena);
}

/// The record's next waiting entry: the one made first; null when none waits.
pub fn next_of(connection: *db.Db, arena: std.mem.Allocator, record_id: []const u8) Error!?Entry {
    std.debug.assert(record_id.len > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    var select = try connection.prepare(
        "SELECT " ++ columns ++ " FROM scheduled_changes WHERE record_id = ?1 AND " ++
            "state = 'waiting' ORDER BY due_at, id LIMIT 1",
    );
    defer select.finalize();

    try select.bind_text(1, record_id);

    if (!try select.step()) {
        return null;
    }

    return try select.read(Entry, arena);
}

/// The scheduled version `id` of the record now publishes `changes`, and `held_back` (null
/// leaves what goes live as it is); whether it had one.
pub fn set_changes(
    connection: *db.Db,
    record_id: []const u8,
    id: i64,
    changes: []const u8,
    held_back: ?[]const u8,
) db.Error!bool {
    std.debug.assert(record_id.len > 0);
    std.debug.assert(changes.len > 0);

    var update = try connection.prepare(
        "UPDATE scheduled_changes SET changes = ?3, held_back = ?4 WHERE record_id = ?1 " ++
            "AND id = ?2 AND changes <> ''",
    );
    defer update.finalize();

    try update.bind_text(1, record_id);
    try update.bind_int(2, id);
    try update.bind_text(3, changes);
    try update.bind_optional_text(4, held_back);
    try update.exec();

    return connection.changes() > 0;
}

/// Every entry of the record built on `from` builds on `to` now (null: what is live).
pub fn rebase(connection: *db.Db, record_id: []const u8, from: i64, to: ?i64) db.Error!void {
    std.debug.assert(record_id.len > 0);
    std.debug.assert(from > 0);

    var update = try connection.prepare(
        "UPDATE scheduled_changes SET base_id = ?3 WHERE record_id = ?1 AND base_id = ?2",
    );
    defer update.finalize();

    try update.bind_text(1, record_id);
    try update.bind_int(2, from);
    try bind_base(&update, 3, to);
    try update.exec();
}

/// The draft `id` scheduled for `due_at`; whether it was one.
pub fn schedule_draft(
    connection: *db.Db,
    id: i64,
    due_at: i64,
    by: []const u8,
    now_ms: i64,
) db.Error!bool {
    std.debug.assert(id > 0);
    std.debug.assert(due_at >= 0);

    var update = try connection.prepare(
        "UPDATE scheduled_changes SET state = 'waiting', due_at = ?2, scheduled_by = ?3, " ++
            "scheduled_at = ?4 WHERE id = ?1 AND state = 'draft'",
    );
    defer update.finalize();

    try update.bind_int(1, id);
    try update.bind_int(2, due_at);
    try update.bind_text(3, by);
    try update.bind_int(4, now_ms);
    try update.exec();

    return connection.changes() > 0;
}

/// Moves the record's waiting entry `id` to `due_at`; whether it had one.
pub fn retime(connection: *db.Db, record_id: []const u8, id: i64, due_at: i64) db.Error!bool {
    std.debug.assert(record_id.len > 0);
    std.debug.assert(due_at >= 0);

    var update = try connection.prepare(
        "UPDATE scheduled_changes SET due_at = ?3 WHERE record_id = ?1 AND id = ?2 AND " ++
            "state = 'waiting'",
    );
    defer update.finalize();

    try update.bind_text(1, record_id);
    try update.bind_int(2, id);
    try update.bind_int(3, due_at);
    try update.exec();

    return connection.changes() > 0;
}

/// Whether `record_id` had the entry `id`: it has not now.
pub fn remove(connection: *db.Db, record_id: []const u8, id: i64) db.Error!bool {
    std.debug.assert(record_id.len > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    var delete = try connection.prepare(
        "DELETE FROM scheduled_changes WHERE record_id = ?1 AND id = ?2",
    );
    defer delete.finalize();

    try delete.bind_text(1, record_id);
    try delete.bind_int(2, id);
    try delete.exec();

    return connection.changes() > 0;
}

/// Drops every `transition` the record has waiting; how many.
pub fn remove_transition(
    connection: *db.Db,
    record_id: []const u8,
    transition: []const u8,
) db.Error!u32 {
    std.debug.assert(record_id.len > 0);
    std.debug.assert(transition.len > 0);

    var delete = try connection.prepare(
        "DELETE FROM scheduled_changes WHERE record_id = ?1 AND transition = ?2",
    );
    defer delete.finalize();

    try delete.bind_text(1, record_id);
    try delete.bind_text(2, transition);
    try delete.exec();

    return @intCast(connection.changes());
}

/// Made: removed.
pub fn made(connection: *db.Db, id: i64) db.Error!void {
    std.debug.assert(id > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    var delete = try connection.prepare("DELETE FROM scheduled_changes WHERE id = ?1");
    defer delete.finalize();

    try delete.bind_int(1, id);
    try delete.exec();
}

/// Refused when it came due: kept, failed, with why; never tried again.
pub fn failed(connection: *db.Db, id: i64, problem: []const u8) db.Error!void {
    std.debug.assert(id > 0);
    std.debug.assert(problem.len > 0);

    var update = try connection.prepare(
        "UPDATE scheduled_changes SET state = 'failed', problem = ?2 WHERE id = ?1",
    );
    defer update.finalize();

    try update.bind_int(1, id);
    try update.bind_text(2, problem[0..@min(problem.len, 1024)]);
    try update.exec();
}

/// When the next waiting entry is due; null when none is.
pub fn next_due(connection: *db.Db) db.Error!?i64 {
    std.debug.assert(connection.transaction_depth <= 8);
    std.debug.assert(take_max > 0);

    var select = try connection.prepare(
        "SELECT due_at FROM scheduled_changes WHERE state = 'waiting' ORDER BY due_at LIMIT 1",
    );
    defer select.finalize();

    if (!try select.step()) {
        return null;
    }

    return select.read_int();
}

/// The waiting entries due by `now_ms`, soonest first, up to `max`.
pub fn due(
    connection: *db.Db,
    arena: std.mem.Allocator,
    now_ms: i64,
    max: u32,
) Error![]const Entry {
    std.debug.assert(max > 0 and max <= take_max);
    std.debug.assert(now_ms >= 0);

    var select = try connection.prepare(
        "SELECT " ++ columns ++ " FROM scheduled_changes WHERE state = 'waiting' AND " ++
            "due_at <= ?1 ORDER BY due_at, id LIMIT ?2",
    );
    defer select.finalize();

    try select.bind_int(1, now_ms);
    try select.bind_int(2, max);

    var rows: std.ArrayList(Entry) = .empty;

    while (try select.step()) {
        std.debug.assert(rows.items.len < max);
        try rows.append(arena, try select.read(Entry, arena));
    }

    return rows.items;
}

test "scheduled changes: many per record, found when due, failed kept, removed" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const connection = &fixture.connection;

    // The records are left out: only the entries are tried here.
    try connection.exec("PRAGMA foreign_keys = OFF");

    const first = try add(connection, .{
        .record_id = "r1",
        .transition = "publish",
        .changes = "{\"title\":\"Deal\"}",
        .due_at = 500,
        .scheduled_by = "u_1",
        .scheduled_at = 1,
    });
    const second = try add(connection, .{
        .record_id = "r1",
        .transition = "archive",
        .due_at = 900,
        .scheduled_by = "u_1",
        .scheduled_at = 2,
    });

    try std.testing.expectEqual(2, (try of_record(connection, arena, "r1")).len);
    try std.testing.expectEqual(1, (try due(connection, arena, 899, 8)).len);
    try failed(connection, first, "Required in Polski");
    try std.testing.expectEqual(0, (try due(connection, arena, 899, 8)).len);
    try std.testing.expectEqual(900, (try next_due(connection)).?);
    try std.testing.expectEqualStrings("failed", (try of_record(connection, arena, "r1"))[0].state);
    try std.testing.expect(try remove(connection, "r1", second));
    try std.testing.expect(!try remove(connection, "r1", second));
    try std.testing.expectEqual(1, try count(connection, "r1"));
}
