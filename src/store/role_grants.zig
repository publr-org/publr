const std = @import("std");
const db = @import("../lib/db.zig");
const role = @import("../model/role.zig");

const grants_max_text = std.fmt.comptimePrint("{d}", .{role.grants_max});

/// Replaces the role's grants with `patterns`, each once.
pub fn set(connection: *db.Db, name: []const u8, patterns: []const []const u8) db.Error!void {
    std.debug.assert(name.len > 0);
    std.debug.assert(patterns.len <= role.grants_max);

    var clear = try connection.prepare("DELETE FROM role_grants WHERE role = ?1");
    defer clear.finalize();

    try clear.bind_text(1, name);
    try clear.exec();

    try add(connection, name, patterns);
}

/// Adds `patterns` the role lacks; ones it holds stay as they are.
pub fn add(connection: *db.Db, name: []const u8, patterns: []const []const u8) db.Error!void {
    std.debug.assert(name.len > 0);
    std.debug.assert(patterns.len <= role.grants_max);

    var insert = try connection.prepare(
        "INSERT OR IGNORE INTO role_grants (role, pattern) VALUES (?1, ?2)",
    );
    defer insert.finalize();

    for (patterns) |pattern| {
        std.debug.assert(pattern.len > 0);

        insert.reset();
        try insert.bind_text(1, name);
        try insert.bind_text(2, pattern);
        try insert.exec();
    }
}

/// Takes `patterns` from the role.
pub fn remove(connection: *db.Db, name: []const u8, patterns: []const []const u8) db.Error!void {
    std.debug.assert(name.len > 0);
    std.debug.assert(patterns.len <= role.grants_max * 4);

    var statement = try connection.prepare(
        "DELETE FROM role_grants WHERE role = ?1 AND pattern = ?2",
    );
    defer statement.finalize();

    for (patterns) |pattern| {
        statement.reset();
        try statement.bind_text(1, name);
        try statement.bind_text(2, pattern);
        try statement.exec();
    }
}

/// The role's grants, in order.
pub fn of(
    connection: *db.Db,
    arena: std.mem.Allocator,
    name: []const u8,
) db.Error![]const []const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(role.grants_max > 0);

    var select = try connection.prepare(
        "SELECT pattern FROM role_grants WHERE role = ?1 ORDER BY pattern LIMIT " ++
            grants_max_text,
    );
    defer select.finalize();

    try select.bind_text(1, name);

    var patterns: std.ArrayList([]const u8) = .empty;

    while (try select.step()) {
        const row = try select.read(struct {
            pattern: []const u8,
        }, arena);

        patterns.append(arena, row.pattern) catch return error.OutOfMemory;
    }

    std.debug.assert(patterns.items.len <= role.grants_max);

    return patterns.items;
}

test "grants are set whole, added once, and read in order" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;

    try connection.exec("INSERT INTO roles (name, label, created_at, updated_at) " ++
        "VALUES ('teacher', 'Teacher', 0, 0)");

    try set(connection, "teacher", &.{ "course.*", "!course.purge" });
    try add(connection, "teacher", &.{ "course.*", "lesson.*" });

    const held = try of(connection, arena, "teacher");
    try std.testing.expectEqual(@as(usize, 3), held.len);
    try std.testing.expectEqualStrings("!course.purge", held[0]);

    try remove(connection, "teacher", &.{ "lesson.*", "course.*" });
    try std.testing.expectEqual(@as(usize, 1), (try of(connection, arena, "teacher")).len);

    try set(connection, "teacher", &.{"lesson.get"});
    try std.testing.expectEqual(@as(usize, 1), (try of(connection, arena, "teacher")).len);
    try std.testing.expectEqual(@as(usize, 0), (try of(connection, arena, "nobody")).len);
    try std.testing.expectError(error.Constraint, add(connection, "nobody", &.{"x.*"}));
}
