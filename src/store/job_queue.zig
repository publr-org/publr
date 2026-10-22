//! The jobs plugins queued (`job_queue`). Code queues one in its own transaction, so a
//! rolled-back write queues nothing; the worker claims the due ones, runs
//! them, and removes them, or moves them later when they fail, until the last attempt.
const std = @import("std");
const db = @import("../lib/db.zig");

pub const Error = db.Error || error{OutOfMemory};

/// Jobs one pass runs: the rest wait for the next.
pub const take_max: u32 = 64;
/// The largest input a job is queued with, as JSON.
pub const input_bytes_max: u32 = 64 << 10;
/// What a failed job keeps of its problem.
pub const problem_len_max: u32 = 1024;

/// One claimed job, in the column order of `claim`.
pub const Claimed = struct {
    id: i64,
    plugin: []const u8,
    name: []const u8,
    input: []const u8,
    attempts: i64,
};

pub const Queued = struct {
    plugin: []const u8,
    name: []const u8,
    input: []const u8,
    due_at_ms: i64,
    now_ms: i64,
};

pub fn push(connection: *db.Db, job: Queued) db.Error!void {
    std.debug.assert(job.plugin.len > 0 and job.name.len > 0);
    std.debug.assert(job.input.len > 0 and job.input.len <= input_bytes_max);

    var insert = try connection.prepare(
        "INSERT INTO job_queue (plugin, name, input, due_at, queued_at) " ++
            "VALUES (?1, ?2, ?3, ?4, ?5)",
    );
    defer insert.finalize();

    try insert.bind_text(1, job.plugin);
    try insert.bind_text(2, job.name);
    try insert.bind_text(3, job.input);
    try insert.bind_int(4, job.due_at_ms);
    try insert.bind_int(5, job.now_ms);
    try insert.exec();
}

/// Work whose first run failed outside the queue (an `on` hook's): kept as a job after one
/// attempt, waiting until `job.due_at_ms`, or failed for good when `ends`.
pub fn push_failed(
    connection: *db.Db,
    job: Queued,
    ends: bool,
    problem: []const u8,
) db.Error!void {
    std.debug.assert(job.plugin.len > 0 and job.name.len > 0);
    std.debug.assert(job.input.len > 0 and job.input.len <= input_bytes_max);
    std.debug.assert(problem.len > 0);

    var insert = try connection.prepare(
        "INSERT INTO job_queue (plugin, name, input, due_at, queued_at, attempts, state, " ++
            "problem) VALUES (?1, ?2, ?3, ?4, ?5, 1, ?6, ?7)",
    );
    defer insert.finalize();

    try insert.bind_text(1, job.plugin);
    try insert.bind_text(2, job.name);
    try insert.bind_text(3, job.input);
    try insert.bind_int(4, job.due_at_ms);
    try insert.bind_int(5, job.now_ms);
    try insert.bind_text(6, if (ends) "failed" else "waiting");
    try insert.bind_text(7, problem[0..@min(problem.len, problem_len_max)]);
    try insert.exec();
}

/// The due jobs, oldest due first, up to `max`, each held until `now_ms + claim_ms`: a run
/// lost to a crash is taken up again once its claim passes.
pub fn claim(
    connection: *db.Db,
    arena: std.mem.Allocator,
    now_ms: i64,
    claim_ms: i64,
    max: u32,
) Error![]const Claimed {
    std.debug.assert(max > 0 and max <= take_max);
    std.debug.assert(claim_ms > 0);

    var update = try connection.prepare(
        "UPDATE job_queue SET claimed_until = ?1 + ?2 WHERE id IN (SELECT id FROM job_queue " ++
            "WHERE state = 'waiting' AND due_at <= ?1 AND claimed_until <= ?1 " ++
            "ORDER BY due_at, id LIMIT ?3) RETURNING id, plugin, name, input, attempts",
    );
    defer update.finalize();

    try update.bind_int(1, now_ms);
    try update.bind_int(2, claim_ms);
    try update.bind_int(3, max);

    var rows: std.ArrayList(Claimed) = .empty;

    while (try update.step()) {
        std.debug.assert(rows.items.len < max);
        try rows.append(arena, try update.read(Claimed, arena));
    }

    return rows.items;
}

/// A job that ran: gone from the queue.
pub fn done(connection: *db.Db, id: i64) db.Error!void {
    std.debug.assert(id > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    var delete = try connection.prepare("DELETE FROM job_queue WHERE id = ?1");
    defer delete.finalize();

    try delete.bind_int(1, id);
    try delete.exec();
}

/// A job that failed and runs again at `due_at_ms`.
pub fn retry(connection: *db.Db, id: i64, due_at_ms: i64, problem: []const u8) db.Error!void {
    std.debug.assert(id > 0);
    std.debug.assert(due_at_ms > 0);

    var update = try connection.prepare(
        "UPDATE job_queue SET attempts = attempts + 1, due_at = ?2, claimed_until = 0, " ++
            "problem = ?3 WHERE id = ?1",
    );
    defer update.finalize();

    try update.bind_int(1, id);
    try update.bind_int(2, due_at_ms);
    try update.bind_text(3, problem[0..@min(problem.len, problem_len_max)]);
    try update.exec();
}

/// A job that failed its last attempt: kept, with why, and never run again.
pub fn fail(connection: *db.Db, id: i64, problem: []const u8) db.Error!void {
    std.debug.assert(id > 0);
    std.debug.assert(problem.len > 0);

    var update = try connection.prepare(
        "UPDATE job_queue SET attempts = attempts + 1, state = 'failed', claimed_until = 0, " ++
            "problem = ?2 WHERE id = ?1",
    );
    defer update.finalize();

    try update.bind_int(1, id);
    try update.bind_text(2, problem[0..@min(problem.len, problem_len_max)]);
    try update.exec();
}

/// A failed job run again (Run again): waiting from `now_ms`, its tries counted afresh.
/// Whether there was such a failed job.
pub fn run_again(connection: *db.Db, id: i64, now_ms: i64) db.Error!bool {
    std.debug.assert(id > 0);
    std.debug.assert(now_ms >= 0);

    var update = try connection.prepare(
        "UPDATE job_queue SET state = 'waiting', attempts = 0, due_at = ?2, claimed_until = 0 " ++
            "WHERE id = ?1 AND state = 'failed'",
    );
    defer update.finalize();

    try update.bind_int(1, id);
    try update.bind_int(2, now_ms);
    try update.exec();

    return connection.changes() > 0;
}

/// Whether a job of this plugin and name waits to run.
pub fn waiting_for(connection: *db.Db, plugin: []const u8, name: []const u8) db.Error!bool {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(name.len > 0);

    var select = try connection.prepare(
        "SELECT 1 FROM job_queue WHERE state = 'waiting' AND plugin = ?1 AND name = ?2 LIMIT 1",
    );
    defer select.finalize();

    try select.bind_text(1, plugin);
    try select.bind_text(2, name);

    return select.step();
}

/// A job as the operator sees it, in the column order of `list`.
pub const Listed = struct {
    id: i64,
    plugin: []const u8,
    name: []const u8,
    input: []const u8,
    due_at: i64,
    attempts: i64,
    state: []const u8,
    problem: []const u8,
};

/// The jobs waiting and failed, soonest due first, up to `max`.
pub fn list(connection: *db.Db, arena: std.mem.Allocator, max: u32) Error![]const Listed {
    std.debug.assert(max > 0 and max <= 1000);
    std.debug.assert(connection.transaction_depth <= 8);

    var select = try connection.prepare(
        "SELECT id, plugin, name, input, due_at, attempts, state, problem FROM job_queue " ++
            "ORDER BY state = 'failed', due_at, id LIMIT ?1",
    );
    defer select.finalize();

    try select.bind_int(1, max);

    var rows: std.ArrayList(Listed) = .empty;

    while (try select.step()) {
        std.debug.assert(rows.items.len < max);
        try rows.append(arena, try select.read(Listed, arena));
    }

    return rows.items;
}

/// When the next waiting job is due; null when none waits.
pub fn next_due(connection: *db.Db) db.Error!?i64 {
    std.debug.assert(connection.transaction_depth <= 8);
    std.debug.assert(take_max > 0);

    var select = try connection.prepare(
        "SELECT due_at FROM job_queue WHERE state = 'waiting' ORDER BY due_at LIMIT 1",
    );
    defer select.finalize();

    if (!try select.step()) {
        return null;
    }

    return select.read_int();
}

test "jobs: claimed when due, held while claimed, retried, failed, done" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const connection = &fixture.connection;

    try push(connection, .{
        .plugin = "shop",
        .name = "release_hold",
        .input = "{\"hold\":\"a\"}",
        .due_at_ms = 100,
        .now_ms = 1,
    });
    try push(connection, .{
        .plugin = "shop",
        .name = "release_hold",
        .input = "{\"hold\":\"b\"}",
        .due_at_ms = 500,
        .now_ms = 1,
    });

    try std.testing.expectEqual(100, (try next_due(connection)).?);
    try std.testing.expectEqual(0, (try claim(connection, arena, 99, 1000, 8)).len);

    const first = try claim(connection, arena, 100, 1000, 8);

    try std.testing.expectEqual(1, first.len);
    try std.testing.expectEqualStrings("{\"hold\":\"a\"}", first[0].input);
    try std.testing.expectEqual(0, (try claim(connection, arena, 150, 1000, 8)).len);

    try retry(connection, first[0].id, 2000, "busy");

    const second = try claim(connection, arena, 600, 1000, 8);

    try std.testing.expectEqual(1, second.len);
    try std.testing.expectEqualStrings("{\"hold\":\"b\"}", second[0].input);
    try done(connection, second[0].id);
    try std.testing.expectEqual(0, (try claim(connection, arena, 1999, 1000, 8)).len);

    const again = try claim(connection, arena, 2000, 1000, 8);

    try std.testing.expectEqual(1, again.len);
    try std.testing.expectEqual(1, again[0].attempts);

    try fail(connection, again[0].id, "gave up");
    try std.testing.expectEqual(null, try next_due(connection));
    try std.testing.expectEqual(0, (try claim(connection, arena, 9999, 1000, 8)).len);

    // Run again: waiting from now, its tries counted afresh; only a failed job.
    try std.testing.expect(try run_again(connection, again[0].id, 9999));
    try std.testing.expect(!try run_again(connection, again[0].id, 9999));
    try std.testing.expectEqual(0, (try claim(connection, arena, 9999, 1000, 8))[0].attempts);
}
