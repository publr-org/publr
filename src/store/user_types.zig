const std = @import("std");
const db = @import("../lib/db.zig");
const user_type = @import("../model/user_type.zig");

pub const held_max = user_type.types_max;

/// Gives `user_id` the type of user `name` (`customer`); false when it held it already.
pub fn add(connection: *db.Db, user_id: []const u8, name: []const u8) db.Error!bool {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(name.len > 0 and name.len <= user_type.name_len_max);

    var insert = try connection.prepare(
        "INSERT OR IGNORE INTO user_types (user_id, user_type) VALUES (?1, ?2)",
    );
    defer insert.finalize();

    try insert.bind_text(1, user_id);
    try insert.bind_text(2, name);
    try insert.exec();

    return connection.changes() == 1;
}

/// Takes the type of user `name` from `user_id`; false when it did not hold it.
pub fn remove(connection: *db.Db, user_id: []const u8, name: []const u8) db.Error!bool {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(name.len > 0 and name.len <= user_type.name_len_max);

    var statement = try connection.prepare(
        "DELETE FROM user_types WHERE user_id = ?1 AND user_type = ?2",
    );
    defer statement.finalize();

    try statement.bind_text(1, user_id);
    try statement.bind_text(2, name);
    try statement.exec();

    return connection.changes() == 1;
}

/// The types of user `user_id` holds, by name; none for staff alone.
pub fn of(
    connection: *db.Db,
    arena: std.mem.Allocator,
    user_id: []const u8,
) db.Error![]const []const u8 {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(held_max > 0);

    var select = try connection.prepare(
        "SELECT user_type FROM user_types WHERE user_id = ?1 ORDER BY user_type LIMIT " ++
            std.fmt.comptimePrint("{d}", .{held_max}),
    );
    defer select.finalize();

    try select.bind_text(1, user_id);

    var names: std.ArrayList([]const u8) = .empty;

    while (try select.step()) {
        const row = try select.read(struct {
            user_type: []const u8,
        }, arena);

        names.append(arena, row.user_type) catch return error.OutOfMemory;
    }

    std.debug.assert(names.items.len <= held_max);

    return names.items;
}

test "an account holds any number of types, each once" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;

    try connection.exec("INSERT INTO users (id, email, display_name, created_at, updated_at) " ++
        "VALUES ('u1', 'ada@example.com', 'Ada', 1, 1)");

    try std.testing.expectEqual(@as(usize, 0), (try of(connection, arena, "u1")).len);
    try std.testing.expect(try add(connection, "u1", "customer"));
    try std.testing.expect(!try add(connection, "u1", "customer"));
    try std.testing.expect(try add(connection, "u1", "affiliate"));

    const held = try of(connection, arena, "u1");

    try std.testing.expectEqual(@as(usize, 2), held.len);
    try std.testing.expectEqualStrings("affiliate", held[0]);
    try std.testing.expect(try remove(connection, "u1", "affiliate"));
    try std.testing.expect(!try remove(connection, "u1", "affiliate"));
    try std.testing.expectEqual(@as(usize, 1), (try of(connection, arena, "u1")).len);
}
