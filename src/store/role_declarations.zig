const std = @import("std");
const db = @import("../lib/db.zig");
const role = @import("../model/role.zig");

/// Whether `owner` declared the role `name` before.
pub fn declared(connection: *db.Db, owner: []const u8, name: []const u8) db.Error!bool {
    std.debug.assert(owner.len > 0);
    std.debug.assert(name.len > 0);

    var select = try connection.prepare(
        "SELECT 1 FROM role_declarations WHERE owner = ?1 AND role = ?2 AND pattern = ''",
    );
    defer select.finalize();

    try select.bind_text(1, owner);
    try select.bind_text(2, name);

    return select.step();
}

/// The grants `owner` last declared for the role `name`.
pub fn patterns_of(
    connection: *db.Db,
    arena: std.mem.Allocator,
    owner: []const u8,
    name: []const u8,
) db.Error![]const []const u8 {
    std.debug.assert(owner.len > 0);
    std.debug.assert(name.len > 0);

    var select = try connection.prepare(
        "SELECT pattern FROM role_declarations WHERE owner = ?1 AND role = ?2 " ++
            "AND pattern != '' ORDER BY pattern",
    );
    defer select.finalize();

    try select.bind_text(1, owner);
    try select.bind_text(2, name);

    return read_patterns(&select, arena);
}

/// Every grant any owner declared for the role `name`, each once.
pub fn patterns_for(
    connection: *db.Db,
    arena: std.mem.Allocator,
    name: []const u8,
) db.Error![]const []const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(name.len <= role.name_len_max);

    var select = try connection.prepare(
        "SELECT DISTINCT pattern FROM role_declarations WHERE role = ?1 AND pattern != '' " ++
            "ORDER BY pattern",
    );
    defer select.finalize();

    try select.bind_text(1, name);

    return read_patterns(&select, arena);
}

/// Records what `owner` declares for the role `name` now, in place of what it did before.
pub fn replace(
    connection: *db.Db,
    owner: []const u8,
    name: []const u8,
    patterns: []const []const u8,
) db.Error!void {
    std.debug.assert(owner.len > 0);
    std.debug.assert(patterns.len <= role.grants_max);

    try forget(connection, owner, name);

    var insert = try connection.prepare(
        "INSERT OR IGNORE INTO role_declarations (owner, role, pattern) VALUES (?1, ?2, ?3)",
    );
    defer insert.finalize();

    try insert.bind_text(1, owner);
    try insert.bind_text(2, name);
    try insert.bind_text(3, "");
    try insert.exec();

    for (patterns) |pattern| {
        std.debug.assert(pattern.len > 0);

        insert.reset();
        try insert.bind_text(1, owner);
        try insert.bind_text(2, name);
        try insert.bind_text(3, pattern);
        try insert.exec();
    }
}

/// Forgets what `owner` declared for the role `name`.
pub fn forget(connection: *db.Db, owner: []const u8, name: []const u8) db.Error!void {
    std.debug.assert(owner.len > 0);
    std.debug.assert(name.len > 0);

    var statement = try connection.prepare(
        "DELETE FROM role_declarations WHERE owner = ?1 AND role = ?2",
    );
    defer statement.finalize();

    try statement.bind_text(1, owner);
    try statement.bind_text(2, name);
    try statement.exec();
}

/// Forgets what every owner declared for the role `name`.
pub fn forget_role(connection: *db.Db, name: []const u8) db.Error!void {
    std.debug.assert(name.len > 0);
    std.debug.assert(name.len <= role.name_len_max);

    var statement = try connection.prepare("DELETE FROM role_declarations WHERE role = ?1");
    defer statement.finalize();

    try statement.bind_text(1, name);
    try statement.exec();
}

fn read_patterns(select: *db.Statement, arena: std.mem.Allocator) db.Error![]const []const u8 {
    std.debug.assert(role.grants_max > 0);

    var patterns: std.ArrayList([]const u8) = .empty;

    while (try select.step()) {
        if (patterns.items.len == role.grants_max * 4) {
            break;
        }

        const row = try select.read(struct {
            pattern: []const u8,
        }, arena);

        patterns.append(arena, row.pattern) catch return error.OutOfMemory;
    }

    std.debug.assert(patterns.items.len <= role.grants_max * 4);

    return patterns.items;
}

test "a declaration is recorded, replaced, merged across owners and forgotten" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;

    try std.testing.expect(!try declared(connection, "shop", "manager"));

    try replace(connection, "shop", "manager", &.{ "shop.*", "order.*" });
    try replace(connection, "newsletter", "manager", &.{"newsletter.*"});
    try replace(connection, "shop", "customer", &.{});

    try std.testing.expect(try declared(connection, "shop", "manager"));
    try std.testing.expect(try declared(connection, "shop", "customer"));
    const shop = try patterns_of(connection, arena, "shop", "manager");
    const both = try patterns_for(connection, arena, "manager");

    try std.testing.expectEqual(@as(usize, 2), shop.len);
    try std.testing.expectEqual(@as(usize, 3), both.len);

    try replace(connection, "shop", "manager", &.{"shop.*"});

    const narrowed = try patterns_of(connection, arena, "shop", "manager");

    try std.testing.expectEqual(@as(usize, 1), narrowed.len);

    try forget(connection, "newsletter", "manager");

    const left = try patterns_for(connection, arena, "manager");

    try std.testing.expectEqual(@as(usize, 1), left.len);

    try forget_role(connection, "manager");
    try std.testing.expect(!try declared(connection, "shop", "manager"));
    try std.testing.expect(try declared(connection, "shop", "customer"));
}
