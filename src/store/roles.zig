const std = @import("std");
const db = @import("../lib/db.zig");
const role = @import("../model/role.zig");

pub const Row = struct {
    name: []const u8,
    label: []const u8,
    description: []const u8 = "",
    /// `core`, the plugin that declared it first, or empty for the site.
    owner: []const u8 = "",
};

pub fn insert(connection: *db.Db, row: Row, now_ms: i64) db.Error!void {
    std.debug.assert(role.valid_name(row.name));
    std.debug.assert(row.label.len > 0 and row.label.len <= role.label_len_max);

    var statement = try connection.prepare(
        "INSERT INTO roles (name, label, description, owner, created_at, updated_at) " ++
            "VALUES (?1, ?2, ?3, ?4, ?5, ?5)",
    );
    defer statement.finalize();

    try statement.bind_text(1, row.name);
    try statement.bind_text(2, row.label);
    try statement.bind_text(3, row.description);
    try statement.bind_text(4, row.owner);
    try statement.bind_int(5, now_ms);
    try statement.exec();
}

/// Changes the label and the description; the name and the owner stay.
pub fn update(connection: *db.Db, row: Row, now_ms: i64) db.Error!void {
    std.debug.assert(role.valid_name(row.name));
    std.debug.assert(row.description.len <= role.description_len_max);

    var statement = try connection.prepare(
        "UPDATE roles SET label = ?2, description = ?3, updated_at = ?4 WHERE name = ?1",
    );
    defer statement.finalize();

    try statement.bind_text(1, row.name);
    try statement.bind_text(2, row.label);
    try statement.bind_text(3, row.description);
    try statement.bind_int(4, now_ms);
    try statement.exec();
}

/// Deletes the role and its grants; who holds it is `user_roles`'.
pub fn delete(connection: *db.Db, name: []const u8) db.Error!void {
    std.debug.assert(name.len > 0);
    std.debug.assert(name.len <= role.name_len_max);

    var statement = try connection.prepare("DELETE FROM roles WHERE name = ?1");
    defer statement.finalize();

    try statement.bind_text(1, name);
    try statement.exec();
}

pub fn get(connection: *db.Db, arena: std.mem.Allocator, name: []const u8) db.Error!?Row {
    std.debug.assert(name.len > 0);
    std.debug.assert(role.name_len_max > 0);

    if (name.len > role.name_len_max) {
        return null;
    }

    var select = try connection.prepare(
        "SELECT name, label, description, owner FROM roles WHERE name = ?1",
    );
    defer select.finalize();

    try select.bind_text(1, name);

    if (!try select.step()) {
        return null;
    }

    return try select.read(Row, arena);
}

/// Every role, in the order they were made.
pub fn list(connection: *db.Db, arena: std.mem.Allocator) db.Error![]const Row {
    std.debug.assert(role.roles_max > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    var select = try connection.prepare(
        "SELECT name, label, description, owner FROM roles ORDER BY rowid LIMIT " ++
            std.fmt.comptimePrint("{d}", .{role.roles_max}),
    );
    defer select.finalize();

    var rows: std.ArrayList(Row) = .empty;

    while (try select.step()) {
        rows.append(arena, try select.read(Row, arena)) catch return error.OutOfMemory;
    }

    std.debug.assert(rows.items.len <= role.roles_max);

    return rows.items;
}

pub fn count(connection: *db.Db) db.Error!u32 {
    std.debug.assert(connection.transaction_depth <= 8);
    std.debug.assert(role.roles_max > 0);

    var select = try connection.prepare("SELECT count(*) FROM roles");
    defer select.finalize();

    std.debug.assert(try select.step());

    return @intCast(select.read_int());
}

test "a role is made, changed, listed in order and deleted with its grants" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;
    const before = try count(connection);

    try insert(connection, .{
        .name = "teacher",
        .label = "Teacher",
        .owner = "courses",
    }, 10);
    try insert(connection, .{
        .name = "auditor",
        .label = "Auditor",
    }, 20);
    try std.testing.expectError(error.Constraint, insert(connection, .{
        .name = "teacher",
        .label = "Again",
    }, 30));

    try update(connection, .{
        .name = "teacher",
        .label = "Lead teacher",
        .description = "Runs the courses",
    }, 40);

    const found = (try get(connection, arena, "teacher")).?;
    try std.testing.expectEqualStrings("Lead teacher", found.label);
    try std.testing.expectEqualStrings("courses", found.owner);
    try std.testing.expect((try get(connection, arena, "nobody")) == null);

    const listed = try list(connection, arena);
    try std.testing.expectEqual(before + 2, listed.len);
    try std.testing.expectEqualStrings("auditor", listed[listed.len - 1].name);

    try connection.exec("INSERT INTO role_grants (role, pattern) VALUES ('teacher', 'course.*')");
    try delete(connection, "teacher");
    try std.testing.expectEqual(before + 1, try count(connection));

    var grants = try connection.prepare("SELECT count(*) FROM role_grants WHERE role = 'teacher'");
    defer grants.finalize();

    std.debug.assert(try grants.step());
    try std.testing.expectEqual(@as(i64, 0), grants.read_int());
}
