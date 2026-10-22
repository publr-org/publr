//! The `shared_rail_pins` table: pages administrators pinned to everyone's rail.

const std = @import("std");
const db = @import("../lib/db.zig");
const rail_pins = @import("rail_pins.zig");

pub const count_max: u32 = rail_pins.per_user_max;

pub const Error = db.Error;
pub const Pin = rail_pins.Pin;

/// Everyone's pins, top to bottom.
pub fn list(connection: *db.Db, arena: std.mem.Allocator) Error![]Pin {
    std.debug.assert(count_max > 0);

    var select = try connection.prepare(
        "SELECT plugin, page FROM shared_rail_pins ORDER BY position, pinned_at LIMIT ?1",
    );
    defer select.finalize();

    try select.bind_int(1, count_max);

    var rows: std.ArrayList(Pin) = .empty;

    while (try select.step()) {
        std.debug.assert(rows.items.len < count_max);
        rows.append(arena, try select.read(Pin, arena)) catch return error.OutOfMemory;
    }

    return rows.items;
}

/// Pins the page last on everyone's rail; pinned already, it stays where it is.
pub fn add(connection: *db.Db, pin: Pin, now_ms: i64) Error!void {
    std.debug.assert(pin.page.len > 0 and pin.page.len <= rail_pins.page_len_max);
    std.debug.assert(now_ms >= 0);

    var statement = try connection.prepare(
        "INSERT INTO shared_rail_pins (plugin, page, position, pinned_at) VALUES (?1, ?2, " ++
            "(SELECT COALESCE(MAX(position), 0) + 1 FROM shared_rail_pins), ?3) " ++
            "ON CONFLICT (plugin, page) DO NOTHING",
    );
    defer statement.finalize();

    try statement.bind_text(1, pin.plugin);
    try statement.bind_text(2, pin.page);
    try statement.bind_int(3, now_ms);
    try statement.exec();
}

/// Whether the page was pinned for everyone; each person's note that they hid it goes too.
pub fn remove(connection: *db.Db, pin: Pin) Error!bool {
    std.debug.assert(pin.page.len > 0);
    std.debug.assert(count_max > 0);

    var statement = try connection.prepare(
        "DELETE FROM shared_rail_pins WHERE plugin = ?1 AND page = ?2",
    );
    defer statement.finalize();

    try statement.bind_text(1, pin.plugin);
    try statement.bind_text(2, pin.page);
    try statement.exec();

    const removed = connection.changes() > 0;

    try rail_pins.forget_hidden(connection, pin);

    return removed;
}

pub fn count(connection: *db.Db) Error!u32 {
    std.debug.assert(count_max > 0);

    var select = try connection.prepare("SELECT COUNT(*) AS count FROM shared_rail_pins");
    defer select.finalize();

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

test "everyone's pins in order; pinned twice stays once; removed with the notes hiding it" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;
    const orders: Pin = .{
        .plugin = "checkout",
        .page = "section/orders",
    };

    try add(connection, .{
        .plugin = "",
        .page = "trash",
    }, 1_000);
    try add(connection, orders, 2_000);
    try add(connection, orders, 3_000);

    const pins = try list(connection, arena);
    try std.testing.expectEqual(@as(usize, 2), pins.len);
    try std.testing.expectEqualStrings("trash", pins[0].page);
    try std.testing.expect(try remove(connection, orders));
    try std.testing.expect(!try remove(connection, orders));
    try std.testing.expectEqual(@as(u32, 1), try count(connection));
}
