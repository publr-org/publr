//! The `taxonomies` table: `store/definitions.zig` over the term domain's tables. A
//! taxonomy definition has the shape of a content type definition (`hierarchical` set
//! when its terms may have parents).

const std = @import("std");
const db = @import("../lib/db.zig");
const taxonomy = @import("../model/taxonomy.zig");
const definitions = @import("definitions.zig");
const tables = @import("tables.zig");

const Store = definitions.Store(tables.terms);

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

test "a taxonomy definition is stored in its own table, apart from the content types" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;

    const id = try insert(connection, arena, taxonomy.test_topics, 1_000);
    const row = (try get_by_handle(connection, arena, "topics")).?;
    try std.testing.expectEqualStrings(id, row.id);
    try std.testing.expect(row.def.hierarchical);
    try std.testing.expectEqual(@as(usize, 1), (try list_briefs(connection, arena)).len);

    const content_types = @import("content_types.zig");
    try std.testing.expect((try content_types.get_by_handle(connection, arena, "topics")) == null);
    try std.testing.expect(try delete(connection, id));
    try std.testing.expect((try get_by_id(connection, arena, id)) == null);
}
