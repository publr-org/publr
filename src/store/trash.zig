const std = @import("std");
const ids = @import("../lib/id.zig");
const next_id = @import("next_id.zig");
const db = @import("../lib/db.zig");

pub const id_len = ids.len;
/// Entries answered at once, at most.
pub const entries_max: u32 = 200;

/// One row of `trash`, without its copy. Field order is the column order of `select_entry`.
pub const Entry = struct {
    id: []const u8,
    kind: []const u8,
    key: []const u8,
    label: []const u8,
    removed_by: []const u8,
    device_id: []const u8,
    conversation_id: []const u8,
    removed_at: i64,
    keep_until: i64,
};

const select_entry = "SELECT id, kind, key, label, removed_by, device_id, conversation_id, " ++
    "removed_at, keep_until FROM trash";

pub const New = struct {
    kind: []const u8,
    key: []const u8,
    label: []const u8,
    removed_by: []const u8 = "",
    device_id: []const u8 = "",
    conversation_id: []const u8 = "",
    keep_until: i64,
    copy: []const u8,
    /// The keys of the media files set aside, one per line.
    files: []const u8 = "",
};

pub fn insert(
    connection: *db.Db,
    io: std.Io,
    arena: std.mem.Allocator,
    new: New,
    now_ms: i64,
) db.Error![]const u8 {
    std.debug.assert(new.kind.len > 0 and new.key.len > 0);
    std.debug.assert(new.keep_until >= now_ms);

    var id_buffer: [id_len]u8 = undefined;
    const made = try next_id.next("trash", connection, io, now_ms, &id_buffer);
    const id = arena.dupe(u8, made) catch return error.OutOfMemory;
    var statement = try connection.prepare(
        "INSERT INTO trash (id, kind, key, label, removed_by, device_id, conversation_id, " ++
            "removed_at, keep_until, copy, files) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, " ++
            "?10, ?11)",
    );
    defer statement.finalize();

    try statement.bind_text(1, id);
    try statement.bind_text(2, new.kind);
    try statement.bind_text(3, new.key);
    try statement.bind_text(4, new.label);
    try statement.bind_text(5, new.removed_by);
    try statement.bind_text(6, new.device_id);
    try statement.bind_text(7, new.conversation_id);
    try statement.bind_int(8, now_ms);
    try statement.bind_int(9, new.keep_until);
    try statement.bind_text(10, new.copy);
    try statement.bind_text(11, new.files);
    try statement.exec();

    return id;
}

/// Which entries a page reads: a conversation's only when named, newest first, `limit` of
/// them from `offset`.
pub const Window = struct {
    conversation_id: []const u8 = "",
    offset: u32 = 0,
    limit: u32,
};

pub fn page(connection: *db.Db, arena: std.mem.Allocator, window: Window) db.Error![]Entry {
    std.debug.assert(window.limit > 0 and window.limit <= entries_max);
    std.debug.assert(window.conversation_id.len <= 64);

    var select = try connection.prepare(select_entry ++
        " WHERE (?1 = '' OR conversation_id = ?1) ORDER BY removed_at DESC, id DESC " ++
        "LIMIT ?2 OFFSET ?3");
    defer select.finalize();

    try select.bind_text(1, window.conversation_id);
    try select.bind_int(2, window.limit);
    try select.bind_int(3, window.offset);

    var rows: std.ArrayList(Entry) = .empty;

    while (try select.step()) {
        std.debug.assert(rows.items.len < window.limit);
        rows.append(arena, try select.read(Entry, arena)) catch return error.OutOfMemory;
    }

    return rows.items;
}

/// How many entries the trash holds; a conversation's only, when named.
pub fn count(connection: *db.Db, conversation_id: []const u8) db.Error!u32 {
    std.debug.assert(conversation_id.len <= 64);
    std.debug.assert(connection.transaction_depth <= 8);

    var select = try connection.prepare(
        "SELECT count(*) FROM trash WHERE ?1 = '' OR conversation_id = ?1",
    );
    defer select.finalize();

    try select.bind_text(1, conversation_id);

    std.debug.assert(try select.step());

    return @intCast(select.read_int());
}

pub fn get(connection: *db.Db, arena: std.mem.Allocator, id: []const u8) db.Error!?Entry {
    std.debug.assert(id.len > 0);

    var select = try connection.prepare(select_entry ++ " WHERE id = ?1");
    defer select.finalize();

    try select.bind_text(1, id);

    if (!try select.step()) {
        return null;
    }

    return try select.read(Entry, arena);
}

pub fn copy_of(connection: *db.Db, arena: std.mem.Allocator, id: []const u8) db.Error!?[]const u8 {
    std.debug.assert(id.len > 0);

    var select = try connection.prepare("SELECT copy FROM trash WHERE id = ?1");
    defer select.finalize();

    try select.bind_text(1, id);

    if (!try select.step()) {
        return null;
    }

    const Row = struct {
        copy: []const u8,
    };

    return (try select.read(Row, arena)).copy;
}

pub fn delete(connection: *db.Db, id: []const u8) db.Error!bool {
    std.debug.assert(id.len > 0);

    var statement = try connection.prepare("DELETE FROM trash WHERE id = ?1");
    defer statement.finalize();

    try statement.bind_text(1, id);
    try statement.exec();

    return connection.changes() == 1;
}

/// The entries kept past their time, the oldest `limit` of them.
pub fn expired(
    connection: *db.Db,
    arena: std.mem.Allocator,
    now_ms: i64,
    limit: u32,
) db.Error![]Entry {
    std.debug.assert(now_ms >= 0);
    std.debug.assert(limit > 0 and limit <= entries_max);

    var select = try connection.prepare(select_entry ++
        " WHERE keep_until <= ?1 ORDER BY removed_at LIMIT ?2");
    defer select.finalize();

    try select.bind_int(1, now_ms);
    try select.bind_int(2, limit);

    var rows: std.ArrayList(Entry) = .empty;

    while (try select.step()) {
        rows.append(arena, try select.read(Entry, arena)) catch return error.OutOfMemory;
    }

    return rows.items;
}

/// The keys of the files an entry set aside, one per line.
pub fn files_of(connection: *db.Db, arena: std.mem.Allocator, id: []const u8) db.Error![]const u8 {
    std.debug.assert(id.len > 0);

    var select = try connection.prepare("SELECT files FROM trash WHERE id = ?1");
    defer select.finalize();

    try select.bind_text(1, id);

    if (!try select.step()) {
        return "";
    }

    const Row = struct {
        files: []const u8,
    };

    return (try select.read(Row, arena)).files;
}

/// Every entry kept `keep_ms` from when it was removed.
pub fn keep_all(connection: *db.Db, keep_ms: i64) db.Error!void {
    std.debug.assert(keep_ms > 0);

    var statement = try connection.prepare("UPDATE trash SET keep_until = removed_at + ?1");
    defer statement.finalize();

    try statement.bind_int(1, keep_ms);
    try statement.exec();
}

/// The modules plugins in the trash name (current, next, previous): kept on disk, so
/// restoring a plugin finds its module.
pub fn plugin_modules(
    connection: *db.Db,
    arena: std.mem.Allocator,
    limit: u32,
) db.Error![]const []const u8 {
    std.debug.assert(limit > 0);
    std.debug.assert(entries_max > 0);

    var select = try connection.prepare(
        "SELECT DISTINCT field.value AS hash FROM trash, json_tree(trash.copy) AS field " ++
            "WHERE trash.kind = 'plugin' AND field.type = 'text' " ++
            "AND field.key IN ('hash', 'next_hash', 'previous_hash') LIMIT ?1",
    );
    defer select.finalize();

    try select.bind_int(1, limit);

    const Hash = struct {
        hash: []const u8,
    };
    var hashes: std.ArrayList([]const u8) = .empty;

    while (try select.step()) {
        std.debug.assert(hashes.items.len < limit);
        const row = try select.read(Hash, arena);

        hashes.append(arena, row.hash) catch return error.OutOfMemory;
    }

    return hashes.items;
}
