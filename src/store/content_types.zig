//! The `content_types` table: `store/definitions.zig` over the record domain's tables.

const std = @import("std");
const db = @import("../lib/db.zig");
const content_type = @import("../model/content_type.zig");
const definitions = @import("definitions.zig");
const tables = @import("tables.zig");

const Store = definitions.Store(tables.records);

pub const Def = definitions.Def;
pub const Row = definitions.Row;
pub const Brief = definitions.Brief;
pub const Error = definitions.Error;
pub const id_len = definitions.id_len;
pub const list_max = definitions.list_max;
pub const insert = Store.insert;
pub const update = Store.update;
pub const get_by_id = Store.get_by_id;
pub const get_by_handle = Store.get_by_handle;
pub const list = Store.list;
pub const list_briefs = Store.list_briefs;
pub const delete = Store.delete;

const test_post = content_type.test_post;

test "insert, encode/decode round trip, get, list, update, delete" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;

    const id = try insert(connection, arena, test_post, 1_000);
    const row = (try get_by_handle(connection, arena, "post")).?;
    try std.testing.expectEqualStrings(id, row.id);
    try std.testing.expectEqual(@as(usize, 5), row.def.fields.len);
    try std.testing.expectEqualStrings("reference", row.def.fields[4].kind);
    try std.testing.expectEqualStrings("tag", row.def.fields[4].options.to[0]);
    try std.testing.expect(row.def.public);

    var renamed = test_post;
    renamed.name = "Article";
    try std.testing.expect(try update(connection, arena, id, renamed, 2_000));
    try std.testing.expectEqualStrings(
        "Article",
        (try get_by_id(connection, arena, id)).?.def.name,
    );
    try std.testing.expectEqual(@as(usize, 1), (try list(connection, arena)).len);

    const briefs = try list_briefs(connection, arena);
    try std.testing.expectEqual(@as(usize, 1), briefs.len);
    try std.testing.expectEqualStrings(id, briefs[0].id);
    try std.testing.expectEqualStrings("post", briefs[0].handle);
    try std.testing.expectEqualStrings("Article", briefs[0].name);
    try std.testing.expectEqual(content_type.Kind.record, briefs[0].kind);
    try std.testing.expect(briefs[0].public);
    try std.testing.expect(!briefs[0].system);
    try std.testing.expectEqual(@as(u32, 5), briefs[0].fields_len);
    try std.testing.expect(try delete(connection, id));
    try std.testing.expect((try get_by_id(connection, arena, id)) == null);
}
