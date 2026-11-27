//! The ids of every unit of a kind a site stores, a page at a time, in order.

const std = @import("std");
const db = @import("../../lib/db.zig");
const shapes = @import("shapes.zig");

const Shape = shapes.Shape;

pub const Error = db.Error || error{ Invalid, OutOfMemory };

/// A unit listed: its id, and its handle when its row has one.
pub const Listed = struct {
    id: []const u8,
    handle: []const u8 = "",
};

/// Up to `limit` units after `after` (empty: from the first), ordered by id.
pub fn list(
    connection: *db.Db,
    arena: std.mem.Allocator,
    shape: Shape,
    after: []const u8,
    limit: u32,
) Error![]const Listed {
    std.debug.assert(limit > 0);
    std.debug.assert(shape.own.key.len > 0);

    const handle: []const u8 = if (shape.handled) "\"handle\"" else "''";
    const scoped: []const u8 = if (shape.own.scope != null) " AND \"scope\" = ?3" else "";
    const sql = try std.fmt.allocPrint(arena, "SELECT \"{s}\" AS id, {s} AS handle " ++
        "FROM \"{s}\" WHERE \"{s}\" > ?1{s} ORDER BY 1 LIMIT ?2", .{
        shape.own.key,
        handle,
        shape.own.name,
        shape.own.key,
        scoped,
    });
    var select = try connection.prepare_dynamic(sql);
    defer select.finalize();

    try select.bind_text(1, after);
    try select.bind_int(2, limit);

    if (shape.own.scope) |scope| {
        try select.bind_text(3, scope);
    }

    var found: std.ArrayList(Listed) = .empty;

    while (try select.step()) {
        try found.append(arena, try select.read(Listed, arena));
    }

    std.debug.assert(found.items.len <= limit);

    return found.items;
}

test "units listed in order a page at a time, a scope's own, a handle beside its id" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const connection = &fixture.connection;

    try connection.exec("INSERT INTO roles (name, label, created_at, updated_at) VALUES " ++
        "('b', 'B', 1, 1), ('a', 'A', 1, 1), ('c', 'C', 1, 1)");
    try connection.exec("INSERT INTO field_groups VALUES ('custom_fields', 'seo', '{}'), " ++
        "('content_types', 't1', '{}')");

    const first = try list(connection, arena, shapes.shape_of(.role), "", 2);

    try std.testing.expectEqual(@as(usize, 2), first.len);
    try std.testing.expectEqualStrings("a", first[0].id);
    try std.testing.expectEqualStrings("", first[0].handle);

    const rest = try list(connection, arena, shapes.shape_of(.role), first[1].id, 2);

    try std.testing.expectEqual(@as(usize, 1), rest.len);
    try std.testing.expectEqualStrings("c", rest[0].id);

    const groups = try list(connection, arena, shapes.shape_of(.field_group), "", 10);

    try std.testing.expectEqual(@as(usize, 1), groups.len);
    try std.testing.expectEqualStrings("seo", groups[0].id);

    try connection.exec("INSERT INTO content_types VALUES ('t1', 'post', 'Post', 'file', 0, " ++
        "0, 'form', '{}', '{}', 1, 1)");

    const types = try list(connection, arena, shapes.shape_of(.content_type), "", 10);

    try std.testing.expectEqual(@as(usize, 1), types.len);
    try std.testing.expectEqualStrings("t1", types[0].id);
    try std.testing.expectEqualStrings("post", types[0].handle);
}
