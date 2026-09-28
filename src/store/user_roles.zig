const std = @import("std");
const db = @import("../lib/db.zig");
const role = @import("../model/role.zig");

pub const roles_max = role.user_roles_max;

/// Replaces the roles `user_id` holds with `roles`, each once.
pub fn set(connection: *db.Db, user_id: []const u8, roles: []const []const u8) db.Error!void {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(roles.len <= roles_max);

    var clear = try connection.prepare("DELETE FROM user_roles WHERE user_id = ?1");
    defer clear.finalize();

    try clear.bind_text(1, user_id);
    try clear.exec();

    var insert = try connection.prepare(
        "INSERT OR IGNORE INTO user_roles (user_id, role) VALUES (?1, ?2)",
    );
    defer insert.finalize();

    for (roles) |name| {
        std.debug.assert(name.len > 0);

        insert.reset();
        try insert.bind_text(1, user_id);
        try insert.bind_text(2, name);
        try insert.exec();
    }
}

/// The roles `user_id` holds, by name.
pub fn of(
    connection: *db.Db,
    arena: std.mem.Allocator,
    user_id: []const u8,
) db.Error![]const []const u8 {
    std.debug.assert(user_id.len > 0);
    std.debug.assert(roles_max > 0);

    var select = try connection.prepare(
        "SELECT role FROM user_roles WHERE user_id = ?1 ORDER BY role LIMIT " ++
            std.fmt.comptimePrint("{d}", .{roles_max}),
    );
    defer select.finalize();

    try select.bind_text(1, user_id);

    var names: std.ArrayList([]const u8) = .empty;

    while (try select.step()) {
        const row = try select.read(struct { role: []const u8 }, arena);

        names.append(arena, row.role) catch return error.OutOfMemory;
    }

    std.debug.assert(names.items.len <= roles_max);

    return names.items;
}

/// How many accounts hold `name`.
pub fn holders(connection: *db.Db, name: []const u8) db.Error!u32 {
    std.debug.assert(name.len > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    var select = try connection.prepare("SELECT count(*) FROM user_roles WHERE role = ?1");
    defer select.finalize();

    try select.bind_text(1, name);

    std.debug.assert(try select.step());

    return @intCast(select.read_int());
}

test "roles are set whole, read in order, counted per role, and go with their account" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;

    try connection.exec("INSERT INTO users (id, email, display_name, created_at, updated_at) " ++
        "VALUES ('u1', 'a@example.com', 'A', 0, 0), ('u2', 'b@example.com', 'B', 0, 0)");

    try set(connection, "u1", &.{ "editor", "admin", "editor" });
    try set(connection, "u2", &.{"subscriber"});

    const held = try of(connection, arena, "u1");
    try std.testing.expectEqual(@as(usize, 2), held.len);
    try std.testing.expectEqualStrings("admin", held[0]);
    try std.testing.expectEqualStrings("editor", held[1]);
    try std.testing.expectEqual(@as(u32, 1), try holders(connection, "admin"));

    try set(connection, "u1", &.{"editor"});
    try std.testing.expectEqual(@as(u32, 0), try holders(connection, "admin"));
    try std.testing.expectEqual(@as(usize, 0), (try of(connection, arena, "u3")).len);

    try connection.exec("DELETE FROM users WHERE id = 'u2'");
    try std.testing.expectEqual(@as(u32, 0), try holders(connection, "subscriber"));
}
