//! `plugin_log`: one row per line a plugin logged (`ctx.log`), with the call it ran in and
//! the activity or error entry it went with. Appended, never changed or removed (triggers
//! refuse it).

const std = @import("std");
const db = @import("../lib/db.zig");
const activity = @import("activity.zig");

pub const list_max = activity.list_max;

pub const Row = struct {
    id: i64,
    at: i64,
    plugin: []const u8,
    /// `info`, `warn` or `err`.
    level: []const u8,
    line: []const u8,
    /// The operation, `job:<plugin>.<name>` or `event:<name>` the line was logged in.
    call: []const u8,
    /// The activity entry it went with; 0 for none.
    activity: i64,
    /// The error entry it went with; 0 for none.
    @"error": i64,
};

pub fn append(connection: *db.Db, row: Row) db.Error!void {
    std.debug.assert(row.plugin.len > 0);
    std.debug.assert(row.call.len > 0);

    var insert = try connection.prepare("INSERT INTO plugin_log (at, plugin, level, line, " ++
        "call, activity, error) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)");
    defer insert.finalize();

    try insert.bind_int(1, row.at);
    try insert.bind_text(2, row.plugin);
    try insert.bind_text(3, row.level);
    try insert.bind_text(4, row.line);
    try insert.bind_text(5, row.call);
    try insert.bind_int(6, row.activity);
    try insert.bind_int(7, row.@"error");
    try insert.exec();
}

/// One plugin's lines, newest first; `before` pages back by id.
pub fn of_plugin(
    connection: *db.Db,
    arena: std.mem.Allocator,
    plugin: []const u8,
    before: ?i64,
    limit: u32,
) db.Error![]const Row {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(limit > 0 and limit <= list_max);

    var select = try connection.prepare("SELECT id, at, plugin, level, line, call, activity, " ++
        "error FROM plugin_log WHERE plugin = ?1 AND (?2 IS NULL OR id < ?2) " ++
        "ORDER BY id DESC LIMIT ?3");
    defer select.finalize();

    try select.bind_text(1, plugin);
    try activity.bind_optional_int(&select, 2, before);
    try select.bind_int(3, limit);

    return collect(&select, arena, limit);
}

pub const Entries = enum { activity, @"error" };

/// The lines that went with the activity or error entries from `oldest` to `newest`, in
/// the order they were logged: one read for a page of either log.
pub fn of_entries(
    connection: *db.Db,
    arena: std.mem.Allocator,
    comptime entries: Entries,
    oldest: i64,
    newest: i64,
) db.Error![]const Row {
    std.debug.assert(oldest > 0);
    std.debug.assert(oldest <= newest);

    var select = try connection.prepare("SELECT id, at, plugin, level, line, call, activity, " ++
        "error FROM plugin_log WHERE " ++ @tagName(entries) ++ " BETWEEN ?1 AND ?2 ORDER BY id");
    defer select.finalize();

    try select.bind_int(1, oldest);
    try select.bind_int(2, newest);

    var rows: std.ArrayList(Row) = .empty;

    while (try select.step()) {
        rows.append(arena, try select.read(Row, arena)) catch return error.OutOfMemory;
    }

    return rows.items;
}

fn collect(select: *db.Statement, arena: std.mem.Allocator, limit: u32) db.Error![]const Row {
    std.debug.assert(limit > 0);

    var rows: std.ArrayList(Row) = .empty;

    while (try select.step()) {
        std.debug.assert(rows.items.len < limit);
        rows.append(arena, try select.read(Row, arena)) catch return error.OutOfMemory;
    }

    return rows.items;
}

test "the plugin log: by plugin newest first, by entry, never changed" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const connection = &fixture.connection;
    const arena = arena_state.allocator();
    const lines = [_][3][]const u8{
        .{ "shop", "info", "Receipt queued" },
        .{ "shop", "err", "Printer offline" },
        .{ "blog", "info", "Feed rebuilt" },
    };

    for (lines, 0..) |line, index| {
        try append(connection, .{
            .id = 0,
            .at = @intCast(index),
            .plugin = line[0],
            .level = line[1],
            .line = line[2],
            .call = "shop.checkout",
            .activity = if (index < 2) 7 else 0,
            .@"error" = 0,
        });
    }

    const shop = try of_plugin(connection, arena, "shop", null, 50);

    try std.testing.expectEqual(@as(usize, 2), shop.len);
    try std.testing.expectEqualStrings("Printer offline", shop[0].line);

    const with_seven = try of_entries(connection, arena, .activity, 7, 7);

    try std.testing.expectEqual(@as(usize, 2), with_seven.len);
    try std.testing.expectEqualStrings("Receipt queued", with_seven[0].line);

    const refused = if (connection.exec("DELETE FROM plugin_log")) |_| false else |_| true;

    try std.testing.expect(refused);
}
