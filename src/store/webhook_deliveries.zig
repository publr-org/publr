//! What other servers sent to plugins' webhooks (`webhook_deliveries`): each delivery with
//! when it came, whether its signature held, its body, and how its queued run ended.
const std = @import("std");
const db = @import("../lib/db.zig");

pub const Error = db.Error || error{OutOfMemory};

/// What a delivery keeps of its problem and of what its run logged.
pub const problem_len_max: u32 = 1024;
pub const lines_len_max: u32 = 8 << 10;

pub const Received = struct {
    plugin: []const u8,
    name: []const u8,
    /// The sender's own id for it; empty when the webhook names none.
    delivery_id: []const u8,
    received_at: i64,
    /// The address it came from.
    sender: []const u8,
    verified: bool,
    body: []const u8,
    headers: []const u8,
    /// `waiting` (queued to run), `refused` (signature), `unreadable` (body).
    result: []const u8,
};

/// Kept; answers its id.
pub fn add(connection: *db.Db, delivery: Received) db.Error!i64 {
    std.debug.assert(delivery.plugin.len > 0 and delivery.name.len > 0);
    std.debug.assert(delivery.result.len > 0);

    var insert = try connection.prepare(
        "INSERT INTO webhook_deliveries (plugin, name, delivery_id, received_at, sender, " ++
            "verified, body, headers, result) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9) " ++
            "RETURNING id",
    );
    defer insert.finalize();

    try insert.bind_text(1, delivery.plugin);
    try insert.bind_text(2, delivery.name);
    try insert.bind_text(3, delivery.delivery_id);
    try insert.bind_int(4, delivery.received_at);
    try insert.bind_text(5, delivery.sender);
    try insert.bind_int(6, @intFromBool(delivery.verified));
    try insert.bind_text(7, delivery.body);
    try insert.bind_text(8, delivery.headers);
    try insert.bind_text(9, delivery.result);

    if (!try insert.step()) {
        return error.Sqlite;
    }

    return insert.read_int();
}

/// Whether a verified delivery with this id came before: a repeat, dropped.
pub fn seen(
    connection: *db.Db,
    plugin: []const u8,
    name: []const u8,
    delivery_id: []const u8,
) db.Error!bool {
    std.debug.assert(plugin.len > 0 and name.len > 0);
    std.debug.assert(delivery_id.len > 0);

    var select = try connection.prepare(
        "SELECT 1 FROM webhook_deliveries WHERE plugin = ?1 AND name = ?2 AND " ++
            "delivery_id = ?3 AND verified = 1 LIMIT 1",
    );
    defer select.finalize();

    try select.bind_text(1, plugin);
    try select.bind_text(2, name);
    try select.bind_text(3, delivery_id);

    return select.step();
}

pub const Kept = struct {
    id: i64,
    plugin: []const u8,
    name: []const u8,
    verified: bool,
    body: []const u8,
    headers: []const u8,
};

pub fn get(connection: *db.Db, arena: std.mem.Allocator, id: i64) Error!?Kept {
    std.debug.assert(id > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    var select = try connection.prepare(
        "SELECT id, plugin, name, verified, body, headers FROM webhook_deliveries WHERE id = ?1",
    );
    defer select.finalize();

    try select.bind_int(1, id);

    if (!try select.step()) {
        return null;
    }

    return try select.read(Kept, arena);
}

/// How its run ended: `ran`, `waiting` (to try again), `failed`; with why, and what it logged.
pub fn settle(
    connection: *db.Db,
    id: i64,
    result: []const u8,
    problem: []const u8,
    lines: []const u8,
) db.Error!void {
    std.debug.assert(id > 0);
    std.debug.assert(result.len > 0);

    var update = try connection.prepare(
        "UPDATE webhook_deliveries SET result = ?2, problem = ?3, lines = ?4 WHERE id = ?1",
    );
    defer update.finalize();

    try update.bind_int(1, id);
    try update.bind_text(2, result);
    try update.bind_text(3, problem[0..@min(problem.len, problem_len_max)]);
    try update.bind_text(4, lines[0..@min(lines.len, lines_len_max)]);
    try update.exec();
}

/// A delivery as its plugin's page lists it, in the column order of `list`.
pub const Listed = struct {
    id: i64,
    name: []const u8,
    delivery_id: []const u8,
    received_at: i64,
    sender: []const u8,
    verified: bool,
    result: []const u8,
    problem: []const u8,
    lines: []const u8,
};

/// The plugin's deliveries, newest first, up to `max`.
pub fn list(
    connection: *db.Db,
    arena: std.mem.Allocator,
    plugin: []const u8,
    max: u32,
) Error![]const Listed {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(max > 0 and max <= 1000);

    var select = try connection.prepare(
        "SELECT id, name, delivery_id, received_at, sender, verified, result, problem, lines " ++
            "FROM webhook_deliveries WHERE plugin = ?1 ORDER BY id DESC LIMIT ?2",
    );
    defer select.finalize();

    try select.bind_text(1, plugin);
    try select.bind_int(2, max);

    var rows: std.ArrayList(Listed) = .empty;

    while (try select.step()) {
        std.debug.assert(rows.items.len < max);
        try rows.append(arena, try select.read(Listed, arena));
    }

    return rows.items;
}

test "deliveries: kept, a repeat seen, settled, listed newest first" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const connection = &fixture.connection;
    const first = try add(connection, .{
        .plugin = "shop",
        .name = "paid",
        .delivery_id = "evt_1",
        .received_at = 100,
        .sender = "203.0.113.9",
        .verified = true,
        .body = "{}",
        .headers = "",
        .result = "waiting",
    });

    try std.testing.expect(try seen(connection, "shop", "paid", "evt_1"));
    try std.testing.expect(!try seen(connection, "shop", "paid", "evt_2"));

    _ = try add(connection, .{
        .plugin = "shop",
        .name = "paid",
        .delivery_id = "",
        .received_at = 200,
        .sender = "203.0.113.9",
        .verified = false,
        .body = "",
        .headers = "",
        .result = "refused",
    });
    try settle(connection, first, "ran", "", "info: paid\n");

    const listed = try list(connection, arena, "shop", 8);

    try std.testing.expectEqual(2, listed.len);
    try std.testing.expectEqualStrings("refused", listed[0].result);
    try std.testing.expectEqualStrings("ran", listed[1].result);
    try std.testing.expectEqualStrings("{}", (try get(connection, arena, first)).?.body);
}
