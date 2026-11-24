//! `internal_records`: what a plugin keeps for itself, one JSON document per row, always
//! read and written within one plugin's, one app's and one collection's scope.

const std = @import("std");
const ids = @import("../lib/id.zig");
const next_id = @import("next_id.zig");
const db = @import("../lib/db.zig");
const model = @import("../model/internal_record.zig");

pub const id_len = ids.len;
pub const list_max: u32 = 200;

pub const Error = db.Error || error{ NotFound, Conflict };

/// Whose records: the plugin, the app (empty for the project's own) and the collection.
pub const Scope = struct {
    plugin: []const u8,
    app: []const u8,
    kind: []const u8,
};

/// One row. Field order is the column order of `select_row`.
pub const Row = struct {
    id: []const u8,
    document: []const u8,
    version: i64,
    created_at: i64,
    updated_at: i64,
};

/// Records with this indexed field holding this text.
pub const Match = struct {
    field: []const u8,
    value: []const u8,
};

const select_row = "SELECT r.id, r.document, r.version, r.created_at, r.updated_at " ++
    "FROM internal_records r";
const in_scope = "r.plugin = ?1 AND r.app = ?2 AND r.kind = ?3";

pub fn insert(
    connection: *db.Db,
    io: std.Io,
    arena: std.mem.Allocator,
    scope: Scope,
    document: []const u8,
    now_ms: i64,
) Error![]const u8 {
    var id_buffer: [id_len]u8 = undefined;
    const made = try next_id.next("internal_records", connection, io, now_ms, &id_buffer);
    const id = arena.dupe(u8, made) catch return error.OutOfMemory;

    try insert_as(connection, scope, id, document, now_ms);

    return id;
}

/// Inserts under an id the caller chose: the printed examples' records.
pub fn insert_as(
    connection: *db.Db,
    scope: Scope,
    id: []const u8,
    document: []const u8,
    now_ms: i64,
) Error!void {
    assert_scope(scope);
    std.debug.assert(document.len > 0 and document.len <= model.document_bytes_max);

    var statement = try connection.prepare(
        "INSERT INTO internal_records " ++
            "(id, plugin, app, kind, document, version, created_at, updated_at) " ++
            "VALUES (?4, ?1, ?2, ?3, ?5, 1, ?6, ?6)",
    );
    defer statement.finalize();

    try bind_scope(&statement, scope);
    try statement.bind_text(4, id);
    try statement.bind_text(5, document);
    try statement.bind_int(6, now_ms);
    try statement.exec();
}

pub fn get(connection: *db.Db, arena: std.mem.Allocator, scope: Scope, id: []const u8) Error!?Row {
    assert_scope(scope);
    std.debug.assert(id.len > 0);

    var select = try connection.prepare(select_row ++ " WHERE " ++ in_scope ++ " AND r.id = ?4");
    defer select.finalize();

    try bind_scope(&select, scope);
    try select.bind_text(4, id);

    if (!try select.step()) {
        return null;
    }

    return try select.read(Row, arena);
}

/// Replaces the document; refused when `expected_version` is given and the row moved.
pub fn update(
    connection: *db.Db,
    scope: Scope,
    id: []const u8,
    document: []const u8,
    expected_version: ?i64,
    now_ms: i64,
) Error!i64 {
    assert_scope(scope);
    std.debug.assert(document.len > 0 and document.len <= model.document_bytes_max);

    var statement = try connection.prepare(
        "UPDATE internal_records SET document = ?5, version = version + 1, updated_at = ?6 " ++
            "WHERE plugin = ?1 AND app = ?2 AND kind = ?3 AND id = ?4 " ++
            "AND (?7 IS NULL OR version = ?7) RETURNING version",
    );
    defer statement.finalize();

    try bind_scope(&statement, scope);
    try statement.bind_text(4, id);
    try statement.bind_text(5, document);
    try statement.bind_int(6, now_ms);

    if (expected_version) |expected| {
        try statement.bind_int(7, expected);
    } else {
        try statement.bind_null(7);
    }

    if (!try statement.step()) {
        return if (expected_version == null) error.NotFound else error.Conflict;
    }

    return statement.read_int();
}

/// Replaces the document with its computed fields worked out again: the record's version
/// and its last change stay, as no caller changed it.
pub fn refresh(connection: *db.Db, scope: Scope, id: []const u8, document: []const u8) Error!void {
    assert_scope(scope);
    std.debug.assert(document.len > 0 and document.len <= model.document_bytes_max);

    var statement = try connection.prepare(
        "UPDATE internal_records SET document = ?5 " ++
            "WHERE plugin = ?1 AND app = ?2 AND kind = ?3 AND id = ?4",
    );
    defer statement.finalize();

    try bind_scope(&statement, scope);
    try statement.bind_text(4, id);
    try statement.bind_text(5, document);
    try statement.exec();
}

/// Whether the row was there to delete.
pub fn delete(connection: *db.Db, scope: Scope, id: []const u8) Error!bool {
    assert_scope(scope);
    std.debug.assert(id.len > 0);

    var statement = try connection.prepare(
        "DELETE FROM internal_records WHERE plugin = ?1 AND app = ?2 AND kind = ?3 AND id = ?4",
    );
    defer statement.finalize();

    try bind_scope(&statement, scope);
    try statement.bind_text(4, id);
    try statement.exec();

    return connection.changes() == 1;
}

/// A page of the scope's records, newest first; with `match`, only those whose indexed
/// field holds that text.
pub fn list(
    connection: *db.Db,
    arena: std.mem.Allocator,
    scope: Scope,
    match: ?Match,
    limit: u32,
    offset: u32,
) Error![]Row {
    return listed(connection, arena, scope, match, .{
        .limit = limit,
        .offset = offset,
    });
}

/// Which page of a scope's records, and from which end.
pub const Page = struct {
    limit: u32,
    offset: u32 = 0,
    /// The oldest first: the order they were made in.
    oldest: bool = false,
    /// A walk's page: the records after this id in id order (ids are time-ordered), the
    /// empty id for the first page. Found from the index, so the thousandth page costs
    /// what the first does; `offset` makes the store pass over every record before it.
    after: ?[]const u8 = null,
};

const newest_first = " ORDER BY r.created_at DESC, r.id DESC LIMIT ?6 OFFSET ?7";
const oldest_first = " ORDER BY r.created_at ASC, r.id ASC LIMIT ?6 OFFSET ?7";
// A lookup starts from the index of values, so it costs the matches, not the collection.
const from_matched = "FROM internal_record_values v CROSS JOIN internal_records r " ++
    "ON r.id = v.record WHERE v.field = ?4 AND v.value = ?5 AND " ++ in_scope;
const from_every = "FROM internal_records r WHERE " ++ in_scope ++ " AND ?4 IS NULL AND ?5 IS NULL";
const columns = "SELECT r.id, r.document, r.version, r.created_at, r.updated_at ";

/// `list`, from either end.
pub fn listed(
    connection: *db.Db,
    arena: std.mem.Allocator,
    scope: Scope,
    match: ?Match,
    page: Page,
) Error![]Row {
    assert_scope(scope);
    std.debug.assert(page.limit > 0 and page.limit <= list_max);

    if (page.after) |after| {
        std.debug.assert(page.offset == 0);

        return walked(connection, arena, scope, match, page, after);
    }

    var select = if (match == null)
        try connection.prepare_dynamic(if (page.oldest)
            columns ++ from_every ++ oldest_first
        else
            columns ++ from_every ++ newest_first)
    else
        try connection.prepare_dynamic(if (page.oldest)
            columns ++ from_matched ++ oldest_first
        else
            columns ++ from_matched ++ newest_first);
    defer select.finalize();

    try bind_match(&select, scope, match);
    try select.bind_int(6, page.limit);
    try select.bind_int(7, page.offset);

    var rows: std.ArrayList(Row) = .empty;

    while (try select.step()) {
        std.debug.assert(rows.items.len < page.limit);
        rows.append(arena, try select.read(Row, arena)) catch return error.OutOfMemory;
    }

    return rows.items;
}

// A walk goes by id, from the index of values for a match and from the scope's index of ids
// for a whole collection: each page starts where the last one ended.
const walk_matched = columns ++ from_matched;
const walk_every = columns ++ from_every;
const walk_oldest_matched = " AND v.record > ?7 ORDER BY v.record ASC LIMIT ?6";
const walk_newest_matched = " AND v.record < ?7 ORDER BY v.record DESC LIMIT ?6";
const walk_oldest_every = " AND r.id > ?7 ORDER BY r.id ASC LIMIT ?6";
const walk_newest_every = " AND r.id < ?7 ORDER BY r.id DESC LIMIT ?6";
/// Above every id: where a walk from the newest starts. Ids are ASCII and compared byte by
/// byte.
const above_every_id = "\xff";
/// The longest id a walk continues after: an id chosen by its maker may be longer than Publr's
/// own.
pub const id_bytes_max: u32 = 64;

fn walked(
    connection: *db.Db,
    arena: std.mem.Allocator,
    scope: Scope,
    match: ?Match,
    page: Page,
    after: []const u8,
) Error![]Row {
    std.debug.assert(page.offset == 0);
    std.debug.assert(after.len <= id_bytes_max);

    var select = if (match == null)
        try connection.prepare_dynamic(if (page.oldest)
            walk_every ++ walk_oldest_every
        else
            walk_every ++ walk_newest_every)
    else
        try connection.prepare_dynamic(if (page.oldest)
            walk_matched ++ walk_oldest_matched
        else
            walk_matched ++ walk_newest_matched);
    defer select.finalize();

    try bind_match(&select, scope, match);
    try select.bind_int(6, page.limit);
    try select.bind_text(7, if (after.len == 0 and !page.oldest) above_every_id else after);

    var rows: std.ArrayList(Row) = .empty;

    while (try select.step()) {
        std.debug.assert(rows.items.len < page.limit);
        rows.append(arena, try select.read(Row, arena)) catch return error.OutOfMemory;
    }

    return rows.items;
}

/// How many records the scope holds; with `match`, how many whose indexed field holds that
/// text. Counted from the index: no record is read.
/// The records' whole numbers at `path` (`$.size.tallies`) added up; a record without one,
/// or with something else there, adds nothing.
pub fn sum(connection: *db.Db, scope: Scope, match: ?Match, path: []const u8) Error!i64 {
    assert_scope(scope);
    std.debug.assert(std.mem.startsWith(u8, path, "$."));

    const added = "SELECT COALESCE(SUM(CASE WHEN json_type(r.document, ?6) = 'integer' " ++
        "THEN json_extract(r.document, ?6) ELSE 0 END), 0) ";
    var select = if (match == null)
        try connection.prepare(added ++ from_every)
    else
        try connection.prepare(added ++ from_matched);
    defer select.finalize();

    try bind_match(&select, scope, match);
    try select.bind_text(6, path);

    if (!try select.step()) {
        return 0;
    }

    return select.read_int();
}

pub fn count(connection: *db.Db, scope: Scope, match: ?Match) Error!u64 {
    assert_scope(scope);

    var select = if (match == null)
        try connection.prepare("SELECT COUNT(*) " ++ from_every)
    else
        try connection.prepare("SELECT COUNT(*) " ++ from_matched);
    defer select.finalize();

    try bind_match(&select, scope, match);

    if (!try select.step()) {
        return 0;
    }

    const counted = select.read_int();

    std.debug.assert(counted >= 0);

    return @intCast(counted);
}

fn bind_match(statement: *db.Statement, scope: Scope, match: ?Match) Error!void {
    assert_scope(scope);

    try bind_scope(statement, scope);

    if (match) |wanted| {
        std.debug.assert(wanted.field.len > 0);

        try statement.bind_text(4, wanted.field);
        try statement.bind_text(5, wanted.value);
    } else {
        try statement.bind_null(4);
        try statement.bind_null(5);
    }
}

fn bind_scope(statement: *db.Statement, scope: Scope) Error!void {
    assert_scope(scope);

    try statement.bind_text(1, scope.plugin);
    try statement.bind_text(2, scope.app);
    try statement.bind_text(3, scope.kind);
}

fn assert_scope(scope: Scope) void {
    std.debug.assert(scope.plugin.len > 0);
    std.debug.assert(scope.kind.len > 0 and scope.kind.len <= model.kind_len_max);
}

/// One of a plugin's collections, across apps, and how many records it holds.
pub const Collection = struct {
    kind: []const u8,
    count: i64,
};

pub const collections_max: u32 = 64;

pub fn collections_of(
    connection: *db.Db,
    arena: std.mem.Allocator,
    plugin: []const u8,
) Error![]Collection {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(collections_max > 0);

    var select = try connection.prepare(
        "SELECT kind, COUNT(*) AS count FROM internal_records WHERE plugin = ?1 " ++
            "GROUP BY kind ORDER BY kind LIMIT ?2",
    );
    defer select.finalize();

    try select.bind_text(1, plugin);
    try select.bind_int(2, collections_max);

    var rows: std.ArrayList(Collection) = .empty;

    while (try select.step()) {
        std.debug.assert(rows.items.len < collections_max);
        rows.append(arena, try select.read(Collection, arena)) catch return error.OutOfMemory;
    }

    return rows.items;
}

/// The plugins holding internal records, by name, at most `collections_max` of them.
pub fn plugins(connection: *db.Db, arena: std.mem.Allocator) Error![]const []const u8 {
    std.debug.assert(collections_max > 0);

    var select = try connection.prepare(
        "SELECT DISTINCT plugin FROM internal_records ORDER BY plugin LIMIT ?1",
    );
    defer select.finalize();

    try select.bind_int(1, collections_max);

    const Plugin = struct {
        plugin: []const u8,
    };
    var names: std.ArrayList([]const u8) = .empty;

    while (try select.step()) {
        std.debug.assert(names.items.len < collections_max);
        const row = try select.read(Plugin, arena);

        names.append(arena, row.plugin) catch return error.OutOfMemory;
    }

    return names.items;
}

/// The scope's records made before `before_ms`: what is kept only a while.
pub fn delete_before(connection: *db.Db, scope: Scope, before_ms: i64) Error!void {
    assert_scope(scope);
    std.debug.assert(before_ms <= std.math.maxInt(i64));

    var statement = try connection.prepare(
        "DELETE FROM internal_records WHERE plugin = ?1 AND app = ?2 AND kind = ?3 " ++
            "AND created_at < ?4",
    );
    defer statement.finalize();

    try bind_scope(&statement, scope);
    try statement.bind_int(4, before_ms);
    try statement.exec();
}

/// Every record of one of a plugin's collections, across apps.
/// Clears a collection's records whose `created_at` (or `updated_at`) is before `cutoff_ms`,
/// in every app; how many went.
pub fn delete_expired(
    connection: *db.Db,
    plugin: []const u8,
    kind: []const u8,
    from: model.Expires.From,
    cutoff_ms: i64,
) Error!u32 {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(kind.len > 0);

    const by_created = "DELETE FROM internal_records WHERE plugin = ?1 AND kind = ?2 AND " ++
        "created_at < ?3";
    const by_updated = "DELETE FROM internal_records WHERE plugin = ?1 AND kind = ?2 AND " ++
        "updated_at < ?3";
    var statement = switch (from) {
        .created => try connection.prepare(by_created),
        .updated => try connection.prepare(by_updated),
    };
    defer statement.finalize();

    try statement.bind_text(1, plugin);
    try statement.bind_text(2, kind);
    try statement.bind_int(3, cutoff_ms);
    try statement.exec();

    return @intCast(connection.changes());
}

pub fn delete_collection(connection: *db.Db, plugin: []const u8, kind: []const u8) Error!void {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(kind.len > 0);

    var statement = try connection.prepare(
        "DELETE FROM internal_records WHERE plugin = ?1 AND kind = ?2",
    );
    defer statement.finalize();

    try statement.bind_text(1, plugin);
    try statement.bind_text(2, kind);
    try statement.exec();
}

/// Whose collection a record is in, whatever its app; null when there is no such record.
pub fn owner_of(
    connection: *db.Db,
    arena: std.mem.Allocator,
    id: []const u8,
) Error!?Owner {
    std.debug.assert(id.len > 0);
    std.debug.assert(id.len <= 256);

    var select = try connection.prepare(
        "SELECT plugin, kind FROM internal_records WHERE id = ?1",
    );
    defer select.finalize();

    try select.bind_text(1, id);

    if (!try select.step()) {
        return null;
    }

    return try select.read(Owner, arena);
}

/// The plugin and the collection a record is kept in.
pub const Owner = struct {
    plugin: []const u8,
    kind: []const u8,
};

/// The ids of one of a plugin's collections, across apps, as a JSON array.
pub fn ids_of_collection(
    connection: *db.Db,
    arena: std.mem.Allocator,
    plugin: []const u8,
    kind: []const u8,
) Error![]const u8 {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(kind.len > 0);

    var select = try connection.prepare(
        "SELECT json_group_array(id) AS ids FROM internal_records WHERE plugin = ?1 AND kind = ?2",
    );
    defer select.finalize();

    try select.bind_text(1, plugin);
    try select.bind_text(2, kind);

    if (!try select.step()) {
        return "[]";
    }

    const Ids = struct {
        ids: []const u8,
    };

    return (try select.read(Ids, arena)).ids;
}

test "expired records go, in every app, by their creation or last change" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const connection = &fixture.connection;
    const day = std.time.ms_per_day;
    const scope: Scope = .{
        .plugin = "shop",
        .app = "",
        .kind = "code",
    };
    var in_app = scope;

    in_app.app = "store";

    try insert_as(connection, scope, "a00000000000000000000001", "{}", 1 * day);
    try insert_as(connection, in_app, "a00000000000000000000002", "{}", 2 * day);
    try insert_as(connection, scope, "a00000000000000000000003", "{}", 40 * day);

    const cutoff = 9 * day;

    const other_kind = try delete_expired(connection, "shop", "cart", .updated, cutoff);
    const created = try delete_expired(connection, "shop", "code", .created, cutoff);
    const again = try delete_expired(connection, "shop", "code", .updated, cutoff);

    try std.testing.expectEqual(0, other_kind);
    try std.testing.expectEqual(2, created);
    try std.testing.expectEqual(0, again);
}

test "a lookup by an indexed field finds its records from the index, newest first" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const connection = &fixture.connection;
    const values = @import("internal_record_values.zig");
    const scope: Scope = .{
        .plugin = "orders",
        .app = "",
        .kind = "transfer",
    };
    var buffer: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const made = [_][]const u8{
        "b00000000000000000000001",
        "b00000000000000000000002",
        "b00000000000000000000003",
    };
    const keys = [_][]const u8{ "t1", "t2", "t1" };

    for (made, keys, 0..) |id, key, at| {
        try insert_as(connection, scope, id, "{}", @intCast(at + 1));
        try values.replace(connection, id, &.{.{
            .field = "key",
            .value = key,
        }});
    }

    const found = try list(connection, fixed.allocator(), scope, .{
        .field = "key",
        .value = "t1",
    }, 10, 0);

    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings(made[2], found[0].id);
    const every = try list(connection, fixed.allocator(), scope, null, 10, 0);

    try std.testing.expectEqual(@as(usize, 3), every.len);

    var other = scope;

    other.kind = "account";
    try std.testing.expectEqual(@as(usize, 0), (try list(connection, fixed.allocator(), other, .{
        .field = "key",
        .value = "t1",
    }, 10, 0)).len);
}

test "a walk goes page after page by id, from either end, with or without a match" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const connection = &fixture.connection;
    const values = @import("internal_record_values.zig");
    const scope: Scope = .{
        .plugin = "orders",
        .app = "",
        .kind = "line",
    };
    var other = scope;
    var buffer: [16384]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const made = [_][]const u8{
        "c00000000000000000000001",
        "c00000000000000000000002",
        "c00000000000000000000003",
        "c00000000000000000000004",
        "c00000000000000000000005",
    };
    const orders = [_][]const u8{ "o1", "o2", "o1", "o1", "o1" };

    other.kind = "charge";

    for (made, orders) |id, order| {
        try insert_as(connection, scope, id, "{}", 1);
        try values.replace(connection, id, &.{.{
            .field = "order",
            .value = order,
        }});
    }

    try insert_as(connection, other, "c00000000000000000000009", "{}", 1);

    const match: Match = .{
        .field = "order",
        .value = "o1",
    };
    const first = try listed(connection, fixed.allocator(), scope, match, .{
        .limit = 2,
        .oldest = true,
        .after = "",
    });
    const second = try listed(connection, fixed.allocator(), scope, match, .{
        .limit = 2,
        .oldest = true,
        .after = first[1].id,
    });
    const last = try listed(connection, fixed.allocator(), scope, match, .{
        .limit = 2,
        .oldest = true,
        .after = second[1].id,
    });
    const newest = try listed(connection, fixed.allocator(), scope, null, .{
        .limit = 4,
        .after = "",
    });
    const older = try listed(connection, fixed.allocator(), scope, null, .{
        .limit = 4,
        .after = newest[3].id,
    });

    try std.testing.expectEqualStrings(made[0], first[0].id);
    try std.testing.expectEqualStrings(made[2], first[1].id);
    try std.testing.expectEqualStrings(made[3], second[0].id);
    try std.testing.expectEqualStrings(made[4], second[1].id);
    try std.testing.expectEqual(@as(usize, 0), last.len);
    try std.testing.expectEqualStrings(made[4], newest[0].id);
    try std.testing.expectEqualStrings(made[1], newest[3].id);
    try std.testing.expectEqual(@as(usize, 1), older.len);
    try std.testing.expectEqualStrings(made[0], older[0].id);
}
