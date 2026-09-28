const std = @import("std");
const db = @import("../lib/db.zig");
const model = @import("../model.zig");

pub const Scope = enum { content_types, taxonomies, custom_fields };
pub const Def = struct {
    name: []const u8 = "",
    fields: []const model.field.Def,
    options: model.field_group.Options = .{},
};
pub const Error = db.Error || error{Invalid};

pub fn put(
    connection: *db.Db,
    arena: std.mem.Allocator,
    scope: Scope,
    owner: []const u8,
    group: Def,
) Error!void {
    std.debug.assert(owner.len > 0);
    std.debug.assert(group.fields.len <= model.field.fields_max);
    const encoded = try std.json.Stringify.valueAlloc(arena, group, .{});

    if (encoded.len > model.content_type.definition_bytes_max) {
        return error.Invalid;
    }

    var statement = try connection.prepare(
        "INSERT INTO field_groups (scope, owner, definition) VALUES (?1, ?2, ?3) " ++
            "ON CONFLICT(scope, owner) DO UPDATE SET definition = excluded.definition",
    );
    defer statement.finalize();

    try statement.bind_text(1, @tagName(scope));
    try statement.bind_text(2, owner);
    try statement.bind_text(3, encoded);
    try statement.exec();
}

pub fn get(
    connection: *db.Db,
    arena: std.mem.Allocator,
    scope: Scope,
    owner: []const u8,
) Error!?Def {
    std.debug.assert(owner.len > 0);
    std.debug.assert(owner.len <= 128);
    var statement = try connection.prepare(
        "SELECT definition FROM field_groups WHERE scope = ?1 AND owner = ?2",
    );
    defer statement.finalize();

    try statement.bind_text(1, @tagName(scope));
    try statement.bind_text(2, owner);

    if (!try statement.step()) {
        return null;
    }

    const row = try statement.read(struct { definition: []const u8 }, arena);
    const group = @import("../lib/json.zig").parse(Def, arena, row.definition, .{}) catch |err| {
        return if (err == error.OutOfMemory) error.OutOfMemory else error.Invalid;
    };

    if (group.fields.len > model.field.fields_max or !model.field_group.valid(group.options)) {
        return error.Invalid;
    }

    return group;
}

pub fn delete(connection: *db.Db, scope: Scope, owner: []const u8) db.Error!void {
    std.debug.assert(owner.len > 0);
    std.debug.assert(owner.len <= 128);
    var statement = try connection.prepare(
        "DELETE FROM field_groups WHERE scope = ?1 AND owner = ?2",
    );
    defer statement.finalize();

    try statement.bind_text(1, @tagName(scope));
    try statement.bind_text(2, owner);
    try statement.exec();
}

test "existing owner schemas convert once without losing fields or custom destinations" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;
    const types = @import("content_types.zig");
    const settings = @import("settings.zig");
    const original = model.content_type.test_post;
    const id = try types.insert(connection, arena, original, 1);
    const encoded = try model.content_type.encode(arena, original);
    var restore = try connection.prepare("UPDATE content_types SET definition = ?1 WHERE id = ?2");
    defer restore.finalize();
    try restore.bind_text(1, encoded);
    try restore.bind_text(2, id);
    try restore.exec();
    try delete(connection, .content_types, id);
    try settings.set(connection, "custom_fields.user", encoded, 1);
    try settings.delete(connection, "schema.field_groups");
    try db.schema.apply(connection);
    const converted = (try types.get_by_id(connection, arena, id)).?;
    try std.testing.expectEqual(original.fields.len, converted.def.fields.len);
    try std.testing.expectEqualStrings("title", converted.def.fields[0].name);
    try std.testing.expect((try settings.get(connection, arena, "custom_fields.user")) == null);
    try std.testing.expectEqual(
        original.fields.len,
        (try get(
            connection,
            arena,
            .custom_fields,
            "user",
        )).?.fields.len,
    );
    try db.schema.apply(connection);
    try std.testing.expectEqual(
        original.fields.len,
        (try types.get_by_id(
            connection,
            arena,
            id,
        )).?.def.fields.len,
    );
}

pub const Item = struct { owner: []const u8, definition: []const u8 };

pub fn list(connection: *db.Db, arena: std.mem.Allocator, scope: Scope) Error![]const Item {
    std.debug.assert(@intFromEnum(scope) <= 2);
    var statement = try connection.prepare(
        "SELECT owner, definition FROM field_groups WHERE scope = ?1 ORDER BY owner LIMIT 257",
    );
    defer statement.finalize();
    try statement.bind_text(1, @tagName(scope));
    var rows: std.ArrayList(Item) = .empty;

    while (try statement.step()) {
        if (rows.items.len == 256) {
            return error.Invalid;
        }

        try rows.append(arena, try statement.read(Item, arena));
    }

    return rows.items;
}
