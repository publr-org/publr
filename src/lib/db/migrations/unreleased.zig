const std = @import("std");
const db = @import("../../db.zig");

pub const one_way = false;

pub fn up(connection: *db.Db) db.Error!void {
    std.debug.assert(connection.transaction_depth >= 1);

    try add_event_queue(connection);

    // The jobs plugins queue, run once their time comes.
    try connection.exec(
        \\CREATE TABLE IF NOT EXISTS job_queue (
        \\    id INTEGER PRIMARY KEY,
        \\    plugin TEXT NOT NULL,
        \\    name TEXT NOT NULL,
        \\    input TEXT NOT NULL,
        \\    due_at INTEGER NOT NULL,
        \\    attempts INTEGER NOT NULL DEFAULT 0,
        \\    claimed_until INTEGER NOT NULL DEFAULT 0,
        \\    state TEXT NOT NULL DEFAULT 'waiting' CHECK (state IN ('waiting', 'failed')),
        \\    problem TEXT NOT NULL DEFAULT '',
        \\    queued_at INTEGER NOT NULL
        \\) STRICT
    );
    try connection.exec(
        \\CREATE INDEX IF NOT EXISTS job_queue_due ON job_queue (state, due_at)
    );

    // The status transitions people scheduled, made once their time comes.
    try connection.exec(
        \\CREATE TABLE IF NOT EXISTS scheduled_transitions (
        \\    record_id TEXT PRIMARY KEY,
        \\    to_status TEXT NOT NULL,
        \\    due_at INTEGER NOT NULL,
        \\    scheduled_by TEXT NOT NULL,
        \\    scheduled_at INTEGER NOT NULL
        \\) STRICT
    );
    try connection.exec(
        \\CREATE INDEX IF NOT EXISTS scheduled_transitions_due ON scheduled_transitions (due_at)
    );

    // The lists' default views: a person's own, or (no person) everyone's.
    try connection.exec(
        \\CREATE TABLE IF NOT EXISTS default_views (
        \\    user_id    TEXT REFERENCES users(id) ON DELETE CASCADE,
        \\    type_id    TEXT NOT NULL REFERENCES content_types(id) ON DELETE CASCADE,
        \\    query      TEXT NOT NULL,
        \\    updated_by TEXT NOT NULL DEFAULT '',
        \\    updated_at INTEGER NOT NULL
        \\) STRICT
    );
    try connection.exec(
        \\CREATE UNIQUE INDEX IF NOT EXISTS default_views_owner
        \\    ON default_views (ifnull(user_id, ''), type_id)
    );

    // Saved views and rail pins the administrators made for everyone.
    try connection.exec(
        \\CREATE TABLE IF NOT EXISTS shared_views (
        \\    id         TEXT PRIMARY KEY,
        \\    name       TEXT NOT NULL,
        \\    query      TEXT NOT NULL,
        \\    created_by TEXT NOT NULL DEFAULT '',
        \\    created_at INTEGER NOT NULL,
        \\    updated_at INTEGER NOT NULL
        \\) STRICT
    );
    try connection.exec(
        \\CREATE TABLE IF NOT EXISTS shared_rail_pins (
        \\    plugin    TEXT NOT NULL DEFAULT '',
        \\    page      TEXT NOT NULL,
        \\    position  INTEGER NOT NULL,
        \\    pinned_at INTEGER NOT NULL,
        \\    PRIMARY KEY (plugin, page)
        \\) STRICT
    );

    // A person's note that they hid a pin made for everyone.
    if (!try db.schema.has_column(connection, "rail_pins", "hidden")) {
        try connection.exec("ALTER TABLE rail_pins ADD COLUMN hidden INTEGER NOT NULL DEFAULT 0");
    }
}

/// The events waiting for the `on` hooks; 0.4.0's notice_queue is left unread.
fn add_event_queue(connection: *db.Db) db.Error!void {
    std.debug.assert(connection.transaction_depth >= 1);

    try connection.exec(
        \\CREATE TABLE IF NOT EXISTS event_queue (
        \\    id INTEGER PRIMARY KEY,
        \\    operation_id INTEGER NOT NULL,
        \\    name TEXT NOT NULL,
        \\    subject TEXT NOT NULL,
        \\    queued_at INTEGER NOT NULL
        \\) STRICT
    );
}
