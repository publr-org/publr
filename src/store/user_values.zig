//! The `user_values` rows (and the `user_search` index): `store/document_values.zig`
//! over the users, one `live` document per account holding its custom fields.

const std = @import("std");
const db = @import("../lib/db.zig");
const kinds = @import("../model/kinds.zig");
const document_values = @import("document_values.zig");
const tables = @import("tables.zig");

const Store = document_values.Store(tables.users);

pub const Error = document_values.Error;
pub const live = document_values.live;
pub const write = Store.write;
pub const clear = Store.clear;
pub const read = Store.read;
pub const referrers = Store.referrers;
pub const delete_field = Store.delete_field;

/// The one type every user's document is written under; the groups are its top fields.
pub const type_id = "user";

pub const Found = struct {
    record: []const u8,
    value: db.Any,
};

/// One field's live value (a list's first) on each of these accounts that has it, in one
/// read: `ids` is a JSON list of their ids.
pub fn field_values(
    connection: *db.Db,
    arena: std.mem.Allocator,
    field: []const u8,
    ids: []const u8,
) db.Error![]Found {
    std.debug.assert(field.len > 0);
    std.debug.assert(ids.len > 0);

    var select = try connection.prepare(
        "SELECT record, value FROM user_values WHERE slot = 'live' AND field = ?1 " ++
            "AND ordinal = 0 AND record IN (SELECT value FROM json_each(?2))",
    );
    defer select.finalize();

    try select.bind_text(1, field);
    try select.bind_text(2, ids);

    var found: std.ArrayList(Found) = .empty;

    while (try select.step()) {
        found.append(arena, try select.read(Found, arena)) catch return error.OutOfMemory;
    }

    return found.items;
}

test "user values live under the user, apart from record and term values" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;
    const users = @import("users.zig");
    const id = try users.insert(connection, std.testing.io, arena, .{
        .email = "ada@example.com",
        .display_name = "Ada",
        .password_hash = "$argon2id$x",
        .roles = &.{"admin"},
        .now_ms = 1_000,
    });
    const fields = [_]@import("../model/field.zig").Def{.{
        .name = "basic",
        .label = "Basic",
        .kind = "group",
        .fields = &.{.{
            .name = "bio",
            .label = "Bio",
            .kind = "string",
        }},
    }};
    const text = "{\"basic\":{\"bio\":\"Writes Zig\"}}";
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});

    try write(&kinds.core, null, connection, id, live, type_id, &fields, parsed);

    const rows = try read(connection, arena, id, live);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("basic.bio", rows[0].field);

    const values = @import("values.zig");
    try std.testing.expectEqual(@as(usize, 0), (try values.read(connection, arena, id, live)).len);

    try std.testing.expect(try users.delete(connection, id));
    try std.testing.expectEqual(@as(usize, 0), (try read(connection, arena, id, live)).len);
}
