//! The `term_values` rows (and the `term_search` index): `store/document_values.zig`
//! over the term domain's tables.

const std = @import("std");
const db = @import("../lib/db.zig");
const kinds = @import("../model/kinds.zig");
const taxonomy = @import("../model/taxonomy.zig");
const document_values = @import("document_values.zig");
const tables = @import("tables.zig");

const Store = document_values.Store(tables.terms);

pub const Error = document_values.Error;
pub const live = document_values.live;
pub const pending = document_values.pending;
pub const slot_len_max = document_values.slot_len_max;
pub const Referrer = document_values.Referrer;
pub const write = Store.write;
pub const clear = Store.clear;
pub const promote = Store.promote;
pub const slots_of = Store.slots_of;
pub const has_slot = Store.has_slot;
pub const read = Store.read;
pub const read_many = Store.read_many;
pub const Owned = document_values.Owned;
pub const referrers = Store.referrers;
pub const find_by_text = Store.find_by_text;
pub const find_by_integer = Store.find_by_integer;
pub const read_integer = Store.read_integer;
pub const delete_references = Store.delete_references;
pub const read_text = Store.read_text;
pub const delete_field = Store.delete_field;
pub const count_field = Store.count_field;

test "term values live apart from record values" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;
    const taxonomies = @import("taxonomies.zig");
    const terms = @import("terms.zig");
    const taxonomy_id = try taxonomies.insert(connection, arena, taxonomy.test_topics, 0);
    const id = try terms.insert(connection, std.testing.io, arena, .{
        .type_id = taxonomy_id,
        .created_by = null,
        .status = "published",
    }, 0);
    const text = "{\"name\":\"Zig\",\"slug\":\"zig\"}";
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});

    try write(&kinds.core, connection, id, live, taxonomy_id, taxonomy.test_topics.fields, parsed);

    try std.testing.expectEqual(@as(usize, 2), (try read(connection, arena, id, live)).len);
    const by_slug = try find_by_text(connection, arena, taxonomy_id, "slug", "zig");
    try std.testing.expectEqualStrings(id, by_slug.?);
    try std.testing.expect(try has_slot(connection, id, live));

    const values = @import("values.zig");
    try std.testing.expectEqual(@as(usize, 0), (try values.read(connection, arena, id, live)).len);
}
