const std = @import("std");
const db = @import("../../db.zig");

pub const one_way = false;

/// The types of user a plugin registers (`customer`) that each account holds, any number of
/// them, staff accounts included. A database that kept one type per account in
/// `users.user_type` keeps that column, unread; its types move over. And the moments `.due`
/// jobs follow on plugins' internal records. And the ledger's accounts and transfers. And the
/// index a walk over a whole collection of internal records reads.
pub fn up(connection: *db.Db) db.Error!void {
    std.debug.assert(connection.transaction_depth <= 8);

    try connection.exec(
        \\CREATE TABLE IF NOT EXISTS user_types (
        \\    user_id   TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        \\    user_type TEXT NOT NULL,
        \\    PRIMARY KEY (user_id, user_type)
        \\) STRICT
    );
    try connection.exec(
        "CREATE INDEX IF NOT EXISTS user_types_user_type ON user_types(user_type, user_id)",
    );

    try connection.exec(
        \\CREATE TABLE IF NOT EXISTS job_due_internal (
        \\    plugin TEXT NOT NULL,
        \\    name   TEXT NOT NULL,
        \\    record TEXT NOT NULL REFERENCES internal_records(id) ON DELETE CASCADE,
        \\    moment INTEGER NOT NULL,
        \\    PRIMARY KEY (plugin, name, record)
        \\) STRICT
    );

    if (try db.schema.has_column(connection, "users", "user_type")) {
        try connection.exec("INSERT OR IGNORE INTO user_types (user_id, user_type) " ++
            "SELECT id, user_type FROM users WHERE user_type <> ''");
    }

    try ledger_tables(connection);
    try connection.exec("CREATE INDEX IF NOT EXISTS internal_records_walk " ++
        "ON internal_records(plugin, app, kind, id)");

    std.debug.assert(!try db.schema.has_column(connection, "user_types", "role"));
}

/// The ledger's accounts and transfers.
fn ledger_tables(connection: *db.Db) db.Error!void {
    std.debug.assert(connection.transaction_depth <= 8);

    try connection.exec(
        \\CREATE TABLE IF NOT EXISTS ledger_accounts (
        \\    id              TEXT PRIMARY KEY,
        \\    owner           TEXT NOT NULL,
        \\    name            TEXT NOT NULL,
        \\    holder_kind     TEXT NOT NULL DEFAULT '',
        \\    holder          TEXT NOT NULL DEFAULT '',
        \\    key             TEXT NOT NULL DEFAULT '',
        \\    unit            TEXT NOT NULL,
        \\    kind            TEXT NOT NULL,
        \\    limit_kept      TEXT NOT NULL,
        \\    debits_posted   INTEGER NOT NULL DEFAULT 0,
        \\    credits_posted  INTEGER NOT NULL DEFAULT 0,
        \\    debits_pending  INTEGER NOT NULL DEFAULT 0,
        \\    credits_pending INTEGER NOT NULL DEFAULT 0,
        \\    closed          INTEGER NOT NULL DEFAULT 0,
        \\    created_at      INTEGER NOT NULL,
        \\    UNIQUE (owner, name, holder_kind, holder, key, unit)
        \\) STRICT;
        \\CREATE INDEX IF NOT EXISTS ledger_accounts_holder
        \\    ON ledger_accounts (holder) WHERE holder != '';
        \\CREATE INDEX IF NOT EXISTS ledger_accounts_unit ON ledger_accounts (unit, owner);
        \\CREATE TABLE IF NOT EXISTS ledger_transfers (
        \\    id           TEXT PRIMARY KEY,
        \\    maker        TEXT NOT NULL,
        \\    maker_id     TEXT NOT NULL,
        \\    leg          INTEGER NOT NULL DEFAULT 0,
        \\    made_for     TEXT NOT NULL DEFAULT '',
        \\    action       TEXT NOT NULL,
        \\    debit        TEXT NOT NULL REFERENCES ledger_accounts(id),
        \\    credit       TEXT NOT NULL REFERENCES ledger_accounts(id),
        \\    unit         TEXT NOT NULL,
        \\    amount       INTEGER NOT NULL CHECK (amount > 0),
        \\    reason       TEXT NOT NULL,
        \\    hold         TEXT NOT NULL DEFAULT '',
        \\    reverses     TEXT NOT NULL DEFAULT '',
        \\    pair         TEXT NOT NULL DEFAULT '',
        \\    rate         INTEGER NOT NULL DEFAULT 0,
        \\    source       TEXT NOT NULL DEFAULT '',
        \\    chain        TEXT NOT NULL,
        \\    about        TEXT NOT NULL DEFAULT '',
        \\    detail       TEXT NOT NULL DEFAULT '',
        \\    author       TEXT NOT NULL,
        \\    expires_at   INTEGER,
        \\    happened_at  INTEGER NOT NULL,
        \\    posted_at    INTEGER NOT NULL,
        \\    debit_after  INTEGER NOT NULL,
        \\    credit_after INTEGER NOT NULL
        \\) STRICT;
        \\CREATE UNIQUE INDEX IF NOT EXISTS ledger_transfers_maker
        \\    ON ledger_transfers (maker, maker_id, leg) WHERE maker_id != '';
        \\CREATE UNIQUE INDEX IF NOT EXISTS ledger_transfers_hold
        \\    ON ledger_transfers (hold) WHERE hold != '';
        \\CREATE INDEX IF NOT EXISTS ledger_transfers_debit ON ledger_transfers (debit, id);
        \\CREATE INDEX IF NOT EXISTS ledger_transfers_credit ON ledger_transfers (credit, id);
        \\CREATE INDEX IF NOT EXISTS ledger_transfers_about
        \\    ON ledger_transfers (about, id) WHERE about != '';
        \\CREATE INDEX IF NOT EXISTS ledger_transfers_detail
        \\    ON ledger_transfers (detail) WHERE detail != '';
        \\CREATE INDEX IF NOT EXISTS ledger_transfers_reverses
        \\    ON ledger_transfers (reverses) WHERE reverses != '';
    );

    std.debug.assert(try db.schema.has_column(connection, "ledger_transfers", "leg"));
}
