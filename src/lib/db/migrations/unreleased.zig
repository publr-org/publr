const std = @import("std");
const db = @import("../../db.zig");

/// Drafted by `zig build migration-draft`; read it, finish it, keep it small. It says
/// everything itself: never `schema.sql`, never today's code. Since 0.2.1 the database only
/// grew: new tables, their indexes and one column, so it runs again safely.
pub const one_way = false;

pub fn up(connection: *db.Db) db.Error!void {
    std.debug.assert(connection.transaction_depth >= 1);

    try ai_tables(connection);
    try removal_tables(connection);
    try other_tables(connection);

    if (!try db.schema.has_column(connection, "sandboxed_plugins", "remove_data")) {
        try connection.exec(
            "ALTER TABLE sandboxed_plugins ADD COLUMN remove_data TEXT NOT NULL DEFAULT '[]'",
        );
    }
}

/// The agent's conversations, their steps, pictures, activity and browsers.
fn ai_tables(connection: *db.Db) db.Error!void {
    std.debug.assert(connection.transaction_depth >= 1);

    try connection.exec(
        \\CREATE TABLE IF NOT EXISTS ai_activity (
        \\    conversation_id TEXT PRIMARY KEY REFERENCES ai_conversations(id) ON DELETE CASCADE,
        \\    doing TEXT NOT NULL,
        \\    since INTEGER NOT NULL
        \\) STRICT
    );
    try connection.exec(
        \\CREATE TABLE IF NOT EXISTS ai_browsers (
        \\    conversation_id TEXT PRIMARY KEY REFERENCES ai_conversations(id) ON DELETE CASCADE,
        \\    ready_at INTEGER NOT NULL DEFAULT 0,
        \\    number INTEGER NOT NULL DEFAULT 0,
        \\    state TEXT NOT NULL DEFAULT 'idle',
        \\    call TEXT NOT NULL DEFAULT '',
        \\    answer TEXT NOT NULL DEFAULT '',
        \\    failed INTEGER NOT NULL DEFAULT 0,
        \\    picture TEXT NOT NULL DEFAULT ''
        \\) STRICT
    );
    try connection.exec(
        \\CREATE TABLE IF NOT EXISTS ai_conversations (
        \\    id TEXT PRIMARY KEY,
        \\    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        \\    prompt TEXT NOT NULL,
        \\    provider TEXT NOT NULL,
        \\    model TEXT NOT NULL,
        \\    scope TEXT NOT NULL,
        \\    state TEXT NOT NULL,
        \\    answer TEXT NOT NULL DEFAULT '',
        \\    device_id TEXT NOT NULL DEFAULT '',
        \\    input_tokens INTEGER NOT NULL DEFAULT 0,
        \\    output_tokens INTEGER NOT NULL DEFAULT 0,
        \\    created_at INTEGER NOT NULL,
        \\    updated_at INTEGER NOT NULL,
        \\    draft TEXT NOT NULL DEFAULT '',
        \\    cached_tokens INTEGER NOT NULL DEFAULT 0
        \\) STRICT
    );
    try connection.exec(
        \\CREATE TABLE IF NOT EXISTS ai_pictures (
        \\    conversation_id TEXT NOT NULL REFERENCES ai_conversations(id) ON DELETE CASCADE,
        \\    asked INTEGER NOT NULL,
        \\    ordinal INTEGER NOT NULL,
        \\    media_key TEXT NOT NULL,
        \\    PRIMARY KEY(conversation_id, asked, ordinal)
        \\) STRICT
    );
    try connection.exec(
        \\CREATE TABLE IF NOT EXISTS ai_steps (
        \\    conversation_id TEXT NOT NULL REFERENCES ai_conversations(id) ON DELETE CASCADE,
        \\    position INTEGER NOT NULL,
        \\    kind TEXT NOT NULL,
        \\    summary TEXT NOT NULL,
        \\    detail TEXT NOT NULL,
        \\    failed INTEGER NOT NULL DEFAULT 0,
        \\    href TEXT NOT NULL DEFAULT '',
        \\    at INTEGER NOT NULL,
        \\    PRIMARY KEY(conversation_id, position)
        \\) STRICT
    );
    try connection.exec(
        \\CREATE INDEX IF NOT EXISTS ai_conversations_user ON ai_conversations(user_id, created_at)
    );
}

/// Removal lists and the trash.
fn removal_tables(connection: *db.Db) db.Error!void {
    std.debug.assert(connection.transaction_depth >= 1);

    try connection.exec(
        \\CREATE TABLE IF NOT EXISTS removal_items (
        \\    removal_id TEXT NOT NULL REFERENCES removals(id) ON DELETE CASCADE,
        \\    position INTEGER NOT NULL,
        \\    operation TEXT NOT NULL,
        \\    input TEXT NOT NULL,
        \\    label TEXT NOT NULL,
        \\    detail TEXT NOT NULL DEFAULT '',
        \\    blocked TEXT NOT NULL DEFAULT '',
        \\    state TEXT NOT NULL,
        \\    message TEXT NOT NULL DEFAULT '',
        \\    PRIMARY KEY(removal_id, position)
        \\) STRICT
    );
    try connection.exec(
        \\CREATE TABLE IF NOT EXISTS removals (
        \\    id TEXT PRIMARY KEY,
        \\    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        \\    device_id TEXT NOT NULL DEFAULT '',
        \\    conversation_id TEXT NOT NULL DEFAULT '',
        \\    state TEXT NOT NULL,
        \\    created_at INTEGER NOT NULL,
        \\    updated_at INTEGER NOT NULL
        \\) STRICT
    );
    try connection.exec(
        \\CREATE TABLE IF NOT EXISTS trash (
        \\    id TEXT PRIMARY KEY,
        \\    kind TEXT NOT NULL,
        \\    key TEXT NOT NULL,
        \\    label TEXT NOT NULL,
        \\    removed_by TEXT NOT NULL DEFAULT '',
        \\    device_id TEXT NOT NULL DEFAULT '',
        \\    conversation_id TEXT NOT NULL DEFAULT '',
        \\    removed_at INTEGER NOT NULL,
        \\    keep_until INTEGER NOT NULL,
        \\    copy TEXT NOT NULL,
        \\    files TEXT NOT NULL DEFAULT ''
        \\) STRICT
    );
    try connection.exec(
        \\CREATE INDEX IF NOT EXISTS removals_user ON removals(user_id, state, created_at)
    );
    try connection.exec(
        \\CREATE INDEX IF NOT EXISTS trash_removed ON trash(removed_at)
    );
}

/// Migrations, rail pins, Site Health's kept cases and secrets.
fn other_tables(connection: *db.Db) db.Error!void {
    std.debug.assert(connection.transaction_depth >= 1);

    try connection.exec(
        \\CREATE TABLE IF NOT EXISTS health_kept (
        \\    target TEXT NOT NULL,
        \\    app TEXT NOT NULL,
        \\    reason TEXT NOT NULL,
        \\    holders INTEGER NOT NULL,
        \\    kept_at INTEGER NOT NULL,
        \\    PRIMARY KEY(target, app)
        \\) STRICT
    );
    try connection.exec(
        \\CREATE TABLE IF NOT EXISTS migrations (
        \\    source TEXT NOT NULL,
        \\    name TEXT NOT NULL,
        \\    sha256 TEXT NOT NULL,
        \\    one_way INTEGER NOT NULL DEFAULT 0,
        \\    applied_ms INTEGER NOT NULL,
        \\    PRIMARY KEY(source, name)
        \\) STRICT
    );
    try connection.exec(
        \\CREATE TABLE IF NOT EXISTS rail_pins (
        \\    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        \\    plugin TEXT NOT NULL DEFAULT '',
        \\    page TEXT NOT NULL,
        \\    position INTEGER NOT NULL,
        \\    pinned_at INTEGER NOT NULL,
        \\    PRIMARY KEY(user_id, plugin, page)
        \\) STRICT
    );
    try connection.exec(
        \\CREATE TABLE IF NOT EXISTS secrets (
        \\    name TEXT PRIMARY KEY,
        \\    sealed BLOB NOT NULL,
        \\    updated_at INTEGER NOT NULL
        \\) STRICT
    );
}
