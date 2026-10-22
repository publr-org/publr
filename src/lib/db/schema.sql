CREATE TABLE IF NOT EXISTS settings (
    key        TEXT PRIMARY KEY,
    value      TEXT NOT NULL,
    updated_at INTEGER NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS migrations (
    source     TEXT NOT NULL,
    name       TEXT NOT NULL,
    sha256     TEXT NOT NULL,
    one_way    INTEGER NOT NULL DEFAULT 0,
    applied_ms INTEGER NOT NULL,
    PRIMARY KEY (source, name)
) STRICT;

CREATE TABLE IF NOT EXISTS users (
    id                         TEXT PRIMARY KEY,
    email                      TEXT NOT NULL UNIQUE,
    display_name               TEXT NOT NULL,
    password_hash              TEXT,
    password_token_hash        BLOB,
    password_token_expires_at  INTEGER,
    created_at                 INTEGER NOT NULL,
    updated_at                 INTEGER NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS user_roles (
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role    TEXT NOT NULL,
    PRIMARY KEY (user_id, role)
) STRICT;

CREATE INDEX IF NOT EXISTS user_roles_role ON user_roles(role, user_id);

CREATE TABLE IF NOT EXISTS roles (
    name        TEXT PRIMARY KEY,
    label       TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    owner       TEXT NOT NULL DEFAULT '',
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS role_grants (
    role    TEXT NOT NULL REFERENCES roles(name) ON DELETE CASCADE,
    pattern TEXT NOT NULL,
    PRIMARY KEY (role, pattern)
) STRICT;

CREATE TABLE IF NOT EXISTS role_declarations (
    owner   TEXT NOT NULL,
    role    TEXT NOT NULL,
    pattern TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (owner, role, pattern)
) STRICT;

CREATE INDEX IF NOT EXISTS role_declarations_role ON role_declarations(role, owner);

CREATE TABLE IF NOT EXISTS sessions (
    id          TEXT PRIMARY KEY,
    secret_hash BLOB NOT NULL,
    user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at  INTEGER NOT NULL,
    created_at  INTEGER NOT NULL
) STRICT;

CREATE INDEX IF NOT EXISTS sessions_user_id ON sessions(user_id);
CREATE INDEX IF NOT EXISTS sessions_expires_at ON sessions(expires_at);

CREATE TABLE IF NOT EXISTS sign_on_tokens (
    id         TEXT PRIMARY KEY,
    expires_at INTEGER NOT NULL
) STRICT;

CREATE INDEX IF NOT EXISTS sign_on_tokens_expires_at ON sign_on_tokens(expires_at);

CREATE TABLE IF NOT EXISTS devices (
    id           TEXT PRIMARY KEY,
    secret_hash  BLOB NOT NULL,
    user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name         TEXT NOT NULL,
    scope        TEXT NOT NULL,
    created_at   INTEGER NOT NULL,
    last_used_at INTEGER NOT NULL,
    revoked_at   INTEGER
) STRICT;

CREATE INDEX IF NOT EXISTS devices_user_id ON devices(user_id, created_at);

CREATE TABLE IF NOT EXISTS device_requests (
    code_hash  BLOB PRIMARY KEY,
    user_code  TEXT NOT NULL UNIQUE,
    name       TEXT NOT NULL,
    scope      TEXT NOT NULL,
    state      TEXT NOT NULL,
    user_id    TEXT REFERENCES users(id) ON DELETE CASCADE,
    expires_at INTEGER NOT NULL,
    created_at INTEGER NOT NULL
) STRICT;

CREATE INDEX IF NOT EXISTS device_requests_expires_at ON device_requests(expires_at);

CREATE TABLE IF NOT EXISTS identities (
    provider     TEXT NOT NULL,
    provider_id  TEXT NOT NULL,
    user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    email        TEXT,
    created_at   INTEGER NOT NULL,
    last_used_at INTEGER NOT NULL,
    PRIMARY KEY (provider, provider_id)
) STRICT;

CREATE INDEX IF NOT EXISTS identities_user_id ON identities(user_id);

CREATE TABLE IF NOT EXISTS content_types (
    id            TEXT PRIMARY KEY,
    handle        TEXT NOT NULL UNIQUE,
    name          TEXT NOT NULL,
    icon          TEXT NOT NULL,
    public        INTEGER NOT NULL,
    system        INTEGER NOT NULL,
    editor        TEXT NOT NULL,
    editor_config TEXT NOT NULL,
    definition    TEXT NOT NULL,
    created_at    INTEGER NOT NULL,
    updated_at    INTEGER NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS records (
    id         TEXT PRIMARY KEY,
    type_id    TEXT NOT NULL REFERENCES content_types(id) ON DELETE CASCADE,
    status     TEXT NOT NULL,
    changed    INTEGER NOT NULL,
    version    INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    created_by TEXT,
    updated_by TEXT,
    app        TEXT,
    trashed_from TEXT NOT NULL DEFAULT '',
    requested  TEXT NOT NULL DEFAULT '',
    requested_by TEXT
) STRICT;

CREATE INDEX IF NOT EXISTS records_list ON records(type_id, status, updated_at);
CREATE INDEX IF NOT EXISTS records_app ON records(app, updated_at);
CREATE INDEX IF NOT EXISTS records_changed ON records(type_id, updated_at) WHERE changed = 1;

CREATE TABLE IF NOT EXISTS record_values (
    record  TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE,
    slot    TEXT NOT NULL,
    type_id TEXT NOT NULL,
    field   TEXT NOT NULL,
    ordinal INTEGER NOT NULL,
    kind    TEXT NOT NULL,
    value   ANY NOT NULL,
    PRIMARY KEY (record, slot, field, ordinal),
    CHECK ((kind = 'int' AND typeof(value) = 'integer')
        OR (kind = 'real' AND typeof(value) = 'real')
        OR (kind IN ('text', 'ref', 'long') AND typeof(value) = 'text'))
) STRICT;

CREATE INDEX IF NOT EXISTS record_values_lookup
    ON record_values(type_id, field, value, record) WHERE slot = 'live' AND kind <> 'long';
CREATE INDEX IF NOT EXISTS record_values_referrers
    ON record_values(value) WHERE slot = 'live' AND kind = 'ref';

CREATE VIRTUAL TABLE IF NOT EXISTS record_search USING fts5(
    text,
    record UNINDEXED,
    slot UNINDEXED,
    type_id UNINDEXED,
    field UNINDEXED
);

CREATE TABLE IF NOT EXISTS taxonomies (
    id            TEXT PRIMARY KEY,
    handle        TEXT NOT NULL UNIQUE,
    name          TEXT NOT NULL,
    icon          TEXT NOT NULL,
    public        INTEGER NOT NULL,
    system        INTEGER NOT NULL,
    editor        TEXT NOT NULL,
    editor_config TEXT NOT NULL,
    definition    TEXT NOT NULL,
    created_at    INTEGER NOT NULL,
    updated_at    INTEGER NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS terms (
    id         TEXT PRIMARY KEY,
    type_id    TEXT NOT NULL REFERENCES taxonomies(id) ON DELETE CASCADE,
    parent_id  TEXT REFERENCES terms(id) ON DELETE RESTRICT,
    status     TEXT NOT NULL,
    changed    INTEGER NOT NULL,
    version    INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    created_by TEXT,
    updated_by TEXT,
    app        TEXT,
    trashed_from TEXT NOT NULL DEFAULT '',
    requested  TEXT NOT NULL DEFAULT '',
    requested_by TEXT
) STRICT;

CREATE INDEX IF NOT EXISTS terms_list ON terms(type_id, status, updated_at);
CREATE INDEX IF NOT EXISTS terms_changed ON terms(type_id, updated_at) WHERE changed = 1;
CREATE INDEX IF NOT EXISTS terms_parent ON terms(parent_id);

CREATE TABLE IF NOT EXISTS term_values (
    record  TEXT NOT NULL REFERENCES terms(id) ON DELETE CASCADE,
    slot    TEXT NOT NULL,
    type_id TEXT NOT NULL,
    field   TEXT NOT NULL,
    ordinal INTEGER NOT NULL,
    kind    TEXT NOT NULL,
    value   ANY NOT NULL,
    PRIMARY KEY (record, slot, field, ordinal),
    CHECK ((kind = 'int' AND typeof(value) = 'integer')
        OR (kind = 'real' AND typeof(value) = 'real')
        OR (kind IN ('text', 'ref', 'long') AND typeof(value) = 'text'))
) STRICT;

CREATE INDEX IF NOT EXISTS term_values_lookup
    ON term_values(type_id, field, value, record) WHERE slot = 'live' AND kind <> 'long';
CREATE INDEX IF NOT EXISTS term_values_referrers
    ON term_values(value) WHERE slot = 'live' AND kind = 'ref';

CREATE VIRTUAL TABLE IF NOT EXISTS term_search USING fts5(
    text,
    record UNINDEXED,
    slot UNINDEXED,
    type_id UNINDEXED,
    field UNINDEXED
);

CREATE TABLE IF NOT EXISTS user_values (
    record  TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    slot    TEXT NOT NULL,
    type_id TEXT NOT NULL,
    field   TEXT NOT NULL,
    ordinal INTEGER NOT NULL,
    kind    TEXT NOT NULL,
    value   ANY NOT NULL,
    PRIMARY KEY (record, slot, field, ordinal),
    CHECK ((kind = 'int' AND typeof(value) = 'integer')
        OR (kind = 'real' AND typeof(value) = 'real')
        OR (kind IN ('text', 'ref', 'long') AND typeof(value) = 'text'))
) STRICT;

CREATE INDEX IF NOT EXISTS user_values_lookup
    ON user_values(type_id, field, value, record) WHERE slot = 'live' AND kind <> 'long';
CREATE INDEX IF NOT EXISTS user_values_referrers
    ON user_values(value) WHERE slot = 'live' AND kind = 'ref';

CREATE VIRTUAL TABLE IF NOT EXISTS user_search USING fts5(
    text,
    record UNINDEXED,
    slot UNINDEXED,
    type_id UNINDEXED,
    field UNINDEXED
);

CREATE TABLE IF NOT EXISTS record_terms (
    record   TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE,
    slot     TEXT NOT NULL,
    field    TEXT NOT NULL,
    term     TEXT NOT NULL REFERENCES terms(id) ON DELETE CASCADE,
    ordinal  INTEGER NOT NULL,
    explicit INTEGER NOT NULL,
    PRIMARY KEY (record, slot, field, term)
) STRICT;

CREATE INDEX IF NOT EXISTS record_terms_reverse ON record_terms(term, slot, record);

CREATE TABLE IF NOT EXISTS media (
    record      TEXT PRIMARY KEY REFERENCES records(id) ON DELETE CASCADE,
    filename    TEXT NOT NULL,
    mime_type   TEXT NOT NULL,
    size        INTEGER NOT NULL,
    width       INTEGER,
    height      INTEGER,
    storage_key TEXT NOT NULL UNIQUE,
    hash        TEXT NOT NULL,
    private     INTEGER NOT NULL,
    created_at  INTEGER NOT NULL,
    unreviewed  INTEGER NOT NULL DEFAULT 0,
    missing     INTEGER NOT NULL DEFAULT 0
) STRICT;

CREATE INDEX IF NOT EXISTS media_created ON media(created_at, record);
CREATE INDEX IF NOT EXISTS media_hash ON media(hash);

CREATE TABLE IF NOT EXISTS views (
    id         TEXT PRIMARY KEY,
    user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name       TEXT NOT NULL,
    query      TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
) STRICT;

CREATE INDEX IF NOT EXISTS views_user ON views(user_id, name);

CREATE TABLE IF NOT EXISTS rail_pins (
    user_id   TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    plugin    TEXT NOT NULL DEFAULT '',
    page      TEXT NOT NULL,
    position  INTEGER NOT NULL,
    pinned_at INTEGER NOT NULL,
    hidden    INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, plugin, page)
) STRICT;

CREATE TABLE IF NOT EXISTS shared_rail_pins (
    plugin    TEXT NOT NULL DEFAULT '',
    page      TEXT NOT NULL,
    position  INTEGER NOT NULL,
    pinned_at INTEGER NOT NULL,
    PRIMARY KEY (plugin, page)
) STRICT;

CREATE TABLE IF NOT EXISTS shared_views (
    id         TEXT PRIMARY KEY,
    name       TEXT NOT NULL,
    query      TEXT NOT NULL,
    created_by TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS default_views (
    user_id    TEXT REFERENCES users(id) ON DELETE CASCADE,
    type_id    TEXT NOT NULL REFERENCES content_types(id) ON DELETE CASCADE,
    query      TEXT NOT NULL,
    updated_by TEXT NOT NULL DEFAULT '',
    updated_at INTEGER NOT NULL
) STRICT;

CREATE UNIQUE INDEX IF NOT EXISTS default_views_owner
    ON default_views (ifnull(user_id, ''), type_id);

CREATE TABLE IF NOT EXISTS ai_conversations (
    id            TEXT PRIMARY KEY,
    user_id       TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    prompt        TEXT NOT NULL,
    provider      TEXT NOT NULL,
    model         TEXT NOT NULL,
    scope         TEXT NOT NULL,
    state         TEXT NOT NULL,
    answer        TEXT NOT NULL DEFAULT '',
    device_id     TEXT NOT NULL DEFAULT '',
    input_tokens  INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0,
    created_at    INTEGER NOT NULL,
    updated_at    INTEGER NOT NULL,
    draft         TEXT NOT NULL DEFAULT '',
    cached_tokens INTEGER NOT NULL DEFAULT 0
) STRICT;

CREATE INDEX IF NOT EXISTS ai_conversations_user ON ai_conversations(user_id, created_at);

CREATE TABLE IF NOT EXISTS secrets (
    name       TEXT PRIMARY KEY,
    sealed     BLOB NOT NULL,
    updated_at INTEGER NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS ai_steps (
    conversation_id TEXT NOT NULL REFERENCES ai_conversations(id) ON DELETE CASCADE,
    position        INTEGER NOT NULL,
    kind            TEXT NOT NULL,
    summary         TEXT NOT NULL,
    detail          TEXT NOT NULL,
    failed          INTEGER NOT NULL DEFAULT 0,
    href            TEXT NOT NULL DEFAULT '',
    at              INTEGER NOT NULL,
    PRIMARY KEY (conversation_id, position)
) STRICT;

CREATE TABLE IF NOT EXISTS ai_pictures (
    conversation_id TEXT NOT NULL REFERENCES ai_conversations(id) ON DELETE CASCADE,
    asked           INTEGER NOT NULL,
    ordinal         INTEGER NOT NULL,
    media_key       TEXT NOT NULL,
    PRIMARY KEY (conversation_id, asked, ordinal)
) STRICT;

CREATE TABLE IF NOT EXISTS ai_activity (
    conversation_id TEXT PRIMARY KEY REFERENCES ai_conversations(id) ON DELETE CASCADE,
    doing           TEXT NOT NULL,
    since           INTEGER NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS ai_browsers (
    conversation_id TEXT PRIMARY KEY REFERENCES ai_conversations(id) ON DELETE CASCADE,
    ready_at        INTEGER NOT NULL DEFAULT 0,
    number          INTEGER NOT NULL DEFAULT 0,
    state           TEXT NOT NULL DEFAULT 'idle',
    call            TEXT NOT NULL DEFAULT '',
    answer          TEXT NOT NULL DEFAULT '',
    failed          INTEGER NOT NULL DEFAULT 0,
    picture         TEXT NOT NULL DEFAULT ''
) STRICT;

CREATE TABLE IF NOT EXISTS removals (
    id              TEXT PRIMARY KEY,
    user_id         TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id       TEXT NOT NULL DEFAULT '',
    conversation_id TEXT NOT NULL DEFAULT '',
    state           TEXT NOT NULL,
    created_at      INTEGER NOT NULL,
    updated_at      INTEGER NOT NULL
) STRICT;

CREATE INDEX IF NOT EXISTS removals_user ON removals(user_id, state, created_at);

CREATE TABLE IF NOT EXISTS removal_items (
    removal_id TEXT NOT NULL REFERENCES removals(id) ON DELETE CASCADE,
    position   INTEGER NOT NULL,
    operation  TEXT NOT NULL,
    input      TEXT NOT NULL,
    label      TEXT NOT NULL,
    detail     TEXT NOT NULL DEFAULT '',
    blocked    TEXT NOT NULL DEFAULT '',
    state      TEXT NOT NULL,
    message    TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (removal_id, position)
) STRICT;

CREATE TABLE IF NOT EXISTS trash (
    id              TEXT PRIMARY KEY,
    kind            TEXT NOT NULL,
    key             TEXT NOT NULL,
    label           TEXT NOT NULL,
    removed_by      TEXT NOT NULL DEFAULT '',
    device_id       TEXT NOT NULL DEFAULT '',
    conversation_id TEXT NOT NULL DEFAULT '',
    removed_at      INTEGER NOT NULL,
    keep_until      INTEGER NOT NULL,
    copy            TEXT NOT NULL,
    files           TEXT NOT NULL DEFAULT ''
) STRICT;

CREATE INDEX IF NOT EXISTS trash_removed ON trash(removed_at);

CREATE TABLE IF NOT EXISTS health_kept (
    target  TEXT NOT NULL,
    app     TEXT NOT NULL,
    reason  TEXT NOT NULL,
    holders INTEGER NOT NULL,
    kept_at INTEGER NOT NULL,
    PRIMARY KEY (target, app)
) STRICT;

CREATE TABLE IF NOT EXISTS internal_records (
    id         TEXT PRIMARY KEY,
    plugin     TEXT NOT NULL,
    app        TEXT NOT NULL,
    kind       TEXT NOT NULL,
    document   TEXT NOT NULL,
    version    INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
) STRICT;

CREATE INDEX IF NOT EXISTS internal_records_scope
    ON internal_records(plugin, app, kind, created_at);

CREATE TABLE IF NOT EXISTS internal_record_values (
    record TEXT NOT NULL REFERENCES internal_records(id) ON DELETE CASCADE,
    field  TEXT NOT NULL,
    value  TEXT NOT NULL,
    PRIMARY KEY (record, field)
) STRICT;

CREATE INDEX IF NOT EXISTS internal_record_values_lookup
    ON internal_record_values(field, value, record);

CREATE TABLE IF NOT EXISTS snapshots (
    record   TEXT NOT NULL,
    seq      INTEGER NOT NULL,
    kind     TEXT NOT NULL,
    at       INTEGER NOT NULL,
    by       TEXT,
    document TEXT NOT NULL,
    PRIMARY KEY (record, seq)
) STRICT;

CREATE INDEX IF NOT EXISTS snapshots_kind ON snapshots(record, kind, seq);

CREATE TABLE IF NOT EXISTS field_groups (
    scope TEXT NOT NULL,
    owner TEXT NOT NULL,
    definition TEXT NOT NULL,
    PRIMARY KEY (scope, owner)
) STRICT;

CREATE TABLE IF NOT EXISTS sandboxed_plugins (
    name              TEXT PRIMARY KEY,
    version           TEXT NOT NULL,
    hash              TEXT NOT NULL,
    manifest          TEXT NOT NULL,
    enabled            INTEGER NOT NULL,
    granted           TEXT NOT NULL,
    denied            TEXT NOT NULL,
    grants            TEXT NOT NULL,
    next_version      TEXT,
    next_hash         TEXT,
    next_manifest     TEXT,
    previous_version  TEXT,
    previous_hash     TEXT,
    previous_manifest TEXT,
    installed_at      INTEGER NOT NULL,
    updated_at        INTEGER NOT NULL,
    remove_data       TEXT NOT NULL DEFAULT '[]'
) STRICT;

CREATE TABLE IF NOT EXISTS activity (
    id        INTEGER PRIMARY KEY,
    at        INTEGER NOT NULL,
    actor     TEXT NOT NULL,
    app       TEXT NOT NULL,
    operation TEXT NOT NULL,
    input     TEXT NOT NULL,
    units     TEXT NOT NULL,
    calls     TEXT NOT NULL
) STRICT;

CREATE TRIGGER IF NOT EXISTS activity_kept BEFORE UPDATE ON activity
    BEGIN SELECT RAISE(ABORT, 'the activity log is append-only'); END;

CREATE TRIGGER IF NOT EXISTS activity_never_removed BEFORE DELETE ON activity
    BEGIN SELECT RAISE(ABORT, 'the activity log is append-only'); END;

CREATE TABLE IF NOT EXISTS errors (
    id        INTEGER PRIMARY KEY,
    at        INTEGER NOT NULL,
    actor     TEXT NOT NULL,
    app       TEXT NOT NULL,
    operation TEXT NOT NULL,
    input     TEXT NOT NULL,
    calls     TEXT NOT NULL,
    error     TEXT NOT NULL,
    message   TEXT NOT NULL,
    failed_in TEXT NOT NULL
) STRICT;

CREATE TRIGGER IF NOT EXISTS errors_kept BEFORE UPDATE ON errors
    BEGIN SELECT RAISE(ABORT, 'the error log is append-only'); END;

CREATE TRIGGER IF NOT EXISTS errors_never_removed BEFORE DELETE ON errors
    BEGIN SELECT RAISE(ABORT, 'the error log is append-only'); END;

-- What plugins logged (`ctx.log`): each line with the call it ran in (an operation,
-- `job:<plugin>.<name>`, `event:<name>`) and the activity or error entry it went with, 0
-- for none. Append-only like the two logs.
CREATE TABLE IF NOT EXISTS plugin_log (
    id       INTEGER PRIMARY KEY,
    at       INTEGER NOT NULL,
    plugin   TEXT NOT NULL,
    level    TEXT NOT NULL,
    line     TEXT NOT NULL,
    call     TEXT NOT NULL,
    activity INTEGER NOT NULL,
    error    INTEGER NOT NULL
) STRICT;

CREATE INDEX IF NOT EXISTS plugin_log_by_plugin ON plugin_log (plugin, id);
CREATE INDEX IF NOT EXISTS plugin_log_by_activity ON plugin_log (activity) WHERE activity > 0;
CREATE INDEX IF NOT EXISTS plugin_log_by_error ON plugin_log (error) WHERE error > 0;

CREATE TRIGGER IF NOT EXISTS plugin_log_kept BEFORE UPDATE ON plugin_log
    BEGIN SELECT RAISE(ABORT, 'the plugin log is append-only'); END;

CREATE TRIGGER IF NOT EXISTS plugin_log_never_removed BEFORE DELETE ON plugin_log
    BEGIN SELECT RAISE(ABORT, 'the plugin log is append-only'); END;

-- Events waiting for the `on` hooks: written in the transaction that emitted them, so a
-- rolled-back write queues nothing; delivered once it commits, oldest first, then removed.
CREATE TABLE IF NOT EXISTS event_queue (
    id           INTEGER PRIMARY KEY,
    operation_id INTEGER NOT NULL,
    name         TEXT NOT NULL,
    subject      TEXT NOT NULL,
    queued_at    INTEGER NOT NULL
) STRICT;

-- Jobs a plugin's code queued: written in the caller's transaction, so a rolled-back write
-- queues nothing; run once `due_at` comes, removed when done, kept as failed after the last
-- attempt. A claim (`claimed_until`) lets a run lost to a crash run again.
CREATE TABLE IF NOT EXISTS job_queue (
    id            INTEGER PRIMARY KEY,
    plugin        TEXT NOT NULL,
    name          TEXT NOT NULL,
    input         TEXT NOT NULL,
    due_at        INTEGER NOT NULL,
    attempts      INTEGER NOT NULL DEFAULT 0,
    claimed_until INTEGER NOT NULL DEFAULT 0,
    state         TEXT NOT NULL DEFAULT 'waiting' CHECK (state IN ('waiting', 'failed')),
    problem       TEXT NOT NULL DEFAULT '',
    queued_at     INTEGER NOT NULL
) STRICT;
CREATE INDEX IF NOT EXISTS job_queue_due ON job_queue (state, due_at);

-- The moment each `.due` job last queued for a record's datetime field: each value runs once
-- per job; an edit moving it queues the job again for the new one.
CREATE TABLE IF NOT EXISTS job_due (
    plugin TEXT NOT NULL,
    name   TEXT NOT NULL,
    record TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE,
    moment INTEGER NOT NULL,
    PRIMARY KEY (plugin, name, record)
) STRICT;

-- A status transition a person scheduled for a record (`publish` on 5 Nov at 9:00): one per
-- record, made by the worker once `due_at` comes, as `scheduled_by` with their rights then.
CREATE TABLE IF NOT EXISTS scheduled_transitions (
    record_id    TEXT PRIMARY KEY,
    transition   TEXT NOT NULL,
    due_at       INTEGER NOT NULL,
    scheduled_by TEXT NOT NULL,
    scheduled_at INTEGER NOT NULL
) STRICT;
CREATE INDEX IF NOT EXISTS scheduled_transitions_due ON scheduled_transitions (due_at);

-- What other servers sent to plugins' webhooks (`/_webhooks/<plugin>.<name>`): each delivery,
-- whether its signature held, its body, and how its queued run ended. A verified delivery's
-- own id (`delivery_id`) is kept once: a repeat is dropped.
CREATE TABLE IF NOT EXISTS webhook_deliveries (
    id          INTEGER PRIMARY KEY,
    plugin      TEXT NOT NULL,
    name        TEXT NOT NULL,
    delivery_id TEXT NOT NULL DEFAULT '',
    received_at INTEGER NOT NULL,
    sender      TEXT NOT NULL DEFAULT '',
    verified    INTEGER NOT NULL,
    body        TEXT NOT NULL,
    headers     TEXT NOT NULL DEFAULT '',
    result      TEXT NOT NULL,
    problem     TEXT NOT NULL DEFAULT '',
    lines       TEXT NOT NULL DEFAULT ''
) STRICT;
CREATE INDEX IF NOT EXISTS webhook_deliveries_plugin ON webhook_deliveries (plugin, id);
CREATE INDEX IF NOT EXISTS webhook_deliveries_seen
    ON webhook_deliveries (plugin, name, delivery_id) WHERE delivery_id != '';
