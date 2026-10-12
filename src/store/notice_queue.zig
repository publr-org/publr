//! The notices waiting for the extrinsic hooks (`notice_queue`). An operation writes them in
//! its own transaction, so a rolled-back write queues nothing; the server hands them to the
//! hooks once the write has committed, between requests, oldest first.
const std = @import("std");
const db = @import("../lib/db.zig");

pub const Error = db.Error || error{OutOfMemory};

/// Notices one pass hands on: the rest wait for the next.
pub const take_max: u32 = 512;

/// One queued notice, in the column order of `take`.
pub const Queued = struct {
    id: i64,
    operation_id: i64,
    name: []const u8,
    subject: []const u8,
};

pub fn push(
    connection: *db.Db,
    operation_id: u64,
    name: []const u8,
    subject: []const u8,
    now_ms: i64,
) db.Error!void {
    std.debug.assert(name.len > 0);
    std.debug.assert(operation_id != 0);

    var insert = try connection.prepare(
        "INSERT INTO notice_queue (operation_id, name, subject, queued_at) " ++
            "VALUES (?1, ?2, ?3, ?4)",
    );
    defer insert.finalize();

    try insert.bind_int(1, @intCast(operation_id));
    try insert.bind_text(2, name);
    try insert.bind_text(3, subject);
    try insert.bind_int(4, now_ms);
    try insert.exec();
}

/// The oldest notices, up to `max`.
pub fn take(connection: *db.Db, arena: std.mem.Allocator, max: u32) Error![]const Queued {
    std.debug.assert(max > 0 and max <= take_max);
    std.debug.assert(connection.transaction_depth == 0);

    var select = try connection.prepare(
        "SELECT id, operation_id, name, subject FROM notice_queue ORDER BY id LIMIT ?1",
    );
    defer select.finalize();

    try select.bind_int(1, max);

    var rows: std.ArrayList(Queued) = .empty;

    while (try select.step()) {
        std.debug.assert(rows.items.len < max);
        try rows.append(arena, try select.read(Queued, arena));
    }

    return rows.items;
}

/// The notices up to `last_id` handed on: gone from the queue.
pub fn remove_through(connection: *db.Db, last_id: i64) db.Error!void {
    std.debug.assert(last_id > 0);
    std.debug.assert(connection.transaction_depth == 0);

    var delete = try connection.prepare("DELETE FROM notice_queue WHERE id <= ?1");
    defer delete.finalize();

    try delete.bind_int(1, last_id);
    try delete.exec();
}

/// Whether any notice waits.
pub fn waiting(connection: *db.Db) db.Error!bool {
    std.debug.assert(connection.transaction_depth <= 8);

    var select = try connection.prepare("SELECT 1 FROM notice_queue LIMIT 1");
    defer select.finalize();

    return select.step();
}
