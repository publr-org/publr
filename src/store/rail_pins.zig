const std = @import("std");
const db = @import("../lib/db.zig");

pub const per_user_max: u32 = 16;
pub const page_len_max: u32 = 128;

pub const Error = db.Error;

/// One row of `rail_pins`, in the column order of `select_pin`.
pub const Pin = struct {
    plugin: []const u8,
    page: []const u8,
};

/// A person's pins, top to bottom.
pub fn list(connection: *db.Db, arena: std.mem.Allocator, user_id: []const u8) Error![]Pin {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(per_user_max > 0);

    var select = try connection.prepare(
        "SELECT plugin, page FROM rail_pins WHERE user_id = ?1 " ++
            "ORDER BY position, pinned_at LIMIT ?2",
    );
    defer select.finalize();

    try select.bind_text(1, user_id);
    try select.bind_int(2, per_user_max);

    var rows: std.ArrayList(Pin) = .empty;

    while (try select.step()) {
        std.debug.assert(rows.items.len < per_user_max);
        rows.append(arena, try select.read(Pin, arena)) catch return error.OutOfMemory;
    }

    return rows.items;
}

/// Pins the page last on the person's rail; pinned already, it stays where it is.
pub fn add(
    connection: *db.Db,
    user_id: []const u8,
    pin: Pin,
    now_ms: i64,
) Error!void {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(pin.page.len > 0 and pin.page.len <= page_len_max);

    var statement = try connection.prepare(
        "INSERT INTO rail_pins (user_id, plugin, page, position, pinned_at) " ++
            "VALUES (?1, ?2, ?3, " ++
            "(SELECT COALESCE(MAX(position), 0) + 1 FROM rail_pins WHERE user_id = ?1), ?4) " ++
            "ON CONFLICT (user_id, plugin, page) DO NOTHING",
    );
    defer statement.finalize();

    try statement.bind_text(1, user_id);
    try statement.bind_text(2, pin.plugin);
    try statement.bind_text(3, pin.page);
    try statement.bind_int(4, now_ms);
    try statement.exec();
}

/// Whether the page was pinned.
pub fn remove(connection: *db.Db, user_id: []const u8, pin: Pin) Error!bool {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(pin.page.len > 0);

    var statement = try connection.prepare(
        "DELETE FROM rail_pins WHERE user_id = ?1 AND plugin = ?2 AND page = ?3",
    );
    defer statement.finalize();

    try statement.bind_text(1, user_id);
    try statement.bind_text(2, pin.plugin);
    try statement.bind_text(3, pin.page);
    try statement.exec();

    return connection.changes() > 0;
}

pub fn count(connection: *db.Db, user_id: []const u8) Error!u32 {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(per_user_max > 0);

    var select = try connection.prepare(
        "SELECT COUNT(*) AS count FROM rail_pins WHERE user_id = ?1",
    );
    defer select.finalize();

    try select.bind_text(1, user_id);

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
