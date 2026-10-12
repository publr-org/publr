const std = @import("std");
const db = @import("../../db.zig");

/// Started by hand; `zig build migration-draft` checks it against the last release. It says
/// everything itself: never `schema.sql`, never today's code. Only grows the database: a
/// new table, so it runs again safely.
pub const one_way = false;

pub fn up(connection: *db.Db) db.Error!void {
    std.debug.assert(connection.transaction_depth >= 1);

    // The notices waiting for the extrinsic hooks.
    try connection.exec(
        \\CREATE TABLE IF NOT EXISTS notice_queue (
        \\    id INTEGER PRIMARY KEY,
        \\    operation_id INTEGER NOT NULL,
        \\    name TEXT NOT NULL,
        \\    subject TEXT NOT NULL,
        \\    queued_at INTEGER NOT NULL
        \\) STRICT
    );
}
