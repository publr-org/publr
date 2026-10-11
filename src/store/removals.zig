const std = @import("std");
const ids = @import("../lib/id.zig");
const next_id = @import("next_id.zig");
const db = @import("../lib/db.zig");
const removal = @import("../model/removal.zig");

pub const id_len = ids.len;
/// Lists answered at once, at most.
pub const lists_max: u32 = 50;

/// One row of `removals`. Field order is the column order of `select_list`.
pub const List = struct {
    id: []const u8,
    user_id: []const u8,
    device_id: []const u8,
    conversation_id: []const u8,
    state: []const u8,
    created_at: i64,
    updated_at: i64,
};

const select_list = "SELECT id, user_id, device_id, conversation_id, state, created_at, " ++
    "updated_at FROM removals";

/// One row of `removal_items`. Field order is the column order of `select_item`.
pub const Item = struct {
    position: i64,
    operation: []const u8,
    input: []const u8,
    label: []const u8,
    detail: []const u8,
    blocked: []const u8,
    state: []const u8,
    message: []const u8,
};

const select_item = "SELECT position, operation, input, label, detail, blocked, state, " ++
    "message FROM removal_items";

pub const New = struct {
    user_id: []const u8,
    device_id: []const u8,
    conversation_id: []const u8 = "",
};

/// The device's list still waiting, else a new one.
pub fn open_for(
    connection: *db.Db,
    io: std.Io,
    arena: std.mem.Allocator,
    new: New,
    now_ms: i64,
) db.Error![]const u8 {
    std.debug.assert(new.user_id.len > 0);
    std.debug.assert(new.device_id.len > 0);

    var select = try connection.prepare(
        "SELECT id FROM removals WHERE device_id = ?1 AND state = 'waiting' " ++
            "ORDER BY created_at DESC LIMIT 1",
    );
    defer select.finalize();

    try select.bind_text(1, new.device_id);

    if (try select.step()) {
        const Row = struct {
            id: []const u8,
        };

        return (try select.read(Row, arena)).id;
    }

    var id_buffer: [id_len]u8 = undefined;
    const made = try next_id.next("removals", connection, io, now_ms, &id_buffer);
    const id = arena.dupe(u8, made) catch return error.OutOfMemory;
    var insert = try connection.prepare(
        "INSERT INTO removals (id, user_id, device_id, conversation_id, state, created_at, " ++
            "updated_at) VALUES (?1, ?2, ?3, ?4, 'waiting', ?5, ?5)",
    );
    defer insert.finalize();

    try insert.bind_text(1, id);
    try insert.bind_text(2, new.user_id);
    try insert.bind_text(3, new.device_id);
    try insert.bind_text(4, new.conversation_id);
    try insert.bind_int(5, now_ms);
    try insert.exec();

    return id;
}

pub const NewItem = struct {
    operation: []const u8,
    input: []const u8,
    described: removal.Described,
};

/// Adds an item after the list's last; its position, or null once the list is full.
pub fn add(connection: *db.Db, list_id: []const u8, item: NewItem, now_ms: i64) db.Error!?u32 {
    std.debug.assert(list_id.len > 0);
    std.debug.assert(item.input.len <= removal.input_len_max);

    const count = try count_of(connection, list_id);

    if (count >= removal.items_max) {
        return null;
    }

    var insert = try connection.prepare(
        "INSERT INTO removal_items (removal_id, position, operation, input, label, detail, " ++
            "blocked, state) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
    );
    defer insert.finalize();

    const blocked = item.described.blocked.len > 0;

    try insert.bind_text(1, list_id);
    try insert.bind_int(2, count + 1);
    try insert.bind_text(3, item.operation);
    try insert.bind_text(4, item.input);
    try insert.bind_text(5, item.described.label);
    try insert.bind_text(6, item.described.detail);
    try insert.bind_text(7, item.described.blocked);
    try insert.bind_text(8, if (blocked) "blocked" else "waiting");
    try insert.exec();
    try touch(connection, list_id, now_ms);

    return count + 1;
}

pub fn get(connection: *db.Db, arena: std.mem.Allocator, id: []const u8) db.Error!?List {
    std.debug.assert(id.len > 0);

    var select = try connection.prepare(select_list ++ " WHERE id = ?1");
    defer select.finalize();

    try select.bind_text(1, id);

    if (!try select.step()) {
        return null;
    }

    return try select.read(List, arena);
}

/// A person's lists, newest first; only the waiting ones when asked; `limit` of them from
/// `offset`.
pub fn list_by_user(
    connection: *db.Db,
    arena: std.mem.Allocator,
    user_id: []const u8,
    waiting_only: bool,
    offset: u32,
    limit: u32,
) db.Error![]List {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(limit > 0 and limit <= lists_max);

    var select = try connection.prepare(select_list ++
        " WHERE user_id = ?1 AND (?2 = 0 OR state = 'waiting') ORDER BY created_at DESC " ++
        "LIMIT ?3 OFFSET ?4");
    defer select.finalize();

    try select.bind_text(1, user_id);
    try select.bind_int(2, @intFromBool(waiting_only));
    try select.bind_int(3, limit);
    try select.bind_int(4, offset);

    var rows: std.ArrayList(List) = .empty;

    while (try select.step()) {
        std.debug.assert(rows.items.len < limit);
        rows.append(arena, try select.read(List, arena)) catch return error.OutOfMemory;
    }

    return rows.items;
}

/// How many lists `list_by_user` reads in all.
pub fn count_by_user(connection: *db.Db, user_id: []const u8, waiting_only: bool) db.Error!u32 {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    var select = try connection.prepare("SELECT count(*) FROM removals " ++
        "WHERE user_id = ?1 AND (?2 = 0 OR state = 'waiting')");
    defer select.finalize();

    try select.bind_text(1, user_id);
    try select.bind_int(2, @intFromBool(waiting_only));

    std.debug.assert(try select.step());

    return @intCast(select.read_int());
}

/// A list's items in all, and the ones still waiting.
pub const Counts = struct {
    items: u32,
    waiting: u32,
};

pub fn counts(connection: *db.Db, list_id: []const u8) db.Error!Counts {
    std.debug.assert(list_id.len > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    var select = try connection.prepare("SELECT count(*), " ++
        "coalesce(sum(state = 'waiting'), 0) FROM removal_items WHERE removal_id = ?1");
    defer select.finalize();

    try select.bind_text(1, list_id);

    std.debug.assert(try select.step());

    const Row = struct {
        items: i64,
        waiting: i64,
    };
    var buffer: [64]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const row = try select.read(Row, fixed.allocator());

    return .{
        .items = @intCast(row.items),
        .waiting = @intCast(row.waiting),
    };
}

pub fn items(connection: *db.Db, arena: std.mem.Allocator, list_id: []const u8) db.Error![]Item {
    std.debug.assert(list_id.len > 0);
    std.debug.assert(removal.items_max > 0);

    var select = try connection.prepare(select_item ++
        " WHERE removal_id = ?1 ORDER BY position LIMIT ?2");
    defer select.finalize();

    try select.bind_text(1, list_id);
    try select.bind_int(2, removal.items_max);

    var rows: std.ArrayList(Item) = .empty;

    while (try select.step()) {
        rows.append(arena, try select.read(Item, arena)) catch return error.OutOfMemory;
    }

    return rows.items;
}

/// What came of one item.
pub fn settle(
    connection: *db.Db,
    list_id: []const u8,
    position: u32,
    state: removal.ItemState,
    message: []const u8,
) db.Error!void {
    std.debug.assert(list_id.len > 0);
    std.debug.assert(position > 0);

    var update = try connection.prepare(
        "UPDATE removal_items SET state = ?1, message = ?2 WHERE removal_id = ?3 AND " ++
            "position = ?4",
    );
    defer update.finalize();

    try update.bind_text(1, @tagName(state));
    try update.bind_text(2, message);
    try update.bind_text(3, list_id);
    try update.bind_int(4, position);
    try update.exec();
}

/// The list decided: done.
pub fn close(connection: *db.Db, list_id: []const u8, now_ms: i64) db.Error!void {
    std.debug.assert(list_id.len > 0);
    std.debug.assert(now_ms >= 0);

    var update = try connection.prepare(
        "UPDATE removals SET state = 'done', updated_at = ?1 WHERE id = ?2",
    );
    defer update.finalize();

    try update.bind_int(1, now_ms);
    try update.bind_text(2, list_id);
    try update.exec();
}

fn touch(connection: *db.Db, list_id: []const u8, now_ms: i64) db.Error!void {
    std.debug.assert(list_id.len > 0);

    var update = try connection.prepare("UPDATE removals SET updated_at = ?1 WHERE id = ?2");
    defer update.finalize();

    try update.bind_int(1, now_ms);
    try update.bind_text(2, list_id);
    try update.exec();
}

fn count_of(connection: *db.Db, list_id: []const u8) db.Error!u32 {
    std.debug.assert(list_id.len > 0);

    var select = try connection.prepare(
        "SELECT COUNT(*) AS count FROM removal_items WHERE removal_id = ?1",
    );
    defer select.finalize();

    try select.bind_text(1, list_id);

    if (!try select.step()) {
        return 0;
    }

    const Count = struct {
        count: i64,
    };
    var buffer: [64]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const counted = try select.read(Count, fixed.allocator());

    return @intCast(@max(0, counted.count));
}
