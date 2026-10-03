//! The `terms` table: `store/documents.zig` over the term domain's tables, plus what only
//! a term has: a parent in the same taxonomy.

const std = @import("std");
const db = @import("../lib/db.zig");
const taxonomy = @import("../model/taxonomy.zig");
const documents = @import("documents.zig");
const tables = @import("tables.zig");

const Store = documents.Store(tables.terms);

pub const id_len = documents.id_len;
pub const list_max = documents.list_max;
pub const statuses_filter_max = documents.statuses_filter_max;
pub const type_ids_max = documents.type_ids_max;
pub const document_bytes_max = documents.document_bytes_max;
pub const search_len_max = documents.search_len_max;
pub const Error = documents.Error;
pub const Record = documents.Record;
pub const Insert = documents.Insert;
pub const Order = documents.Order;
pub const Filter = documents.Filter;
pub const Author = documents.Author;
pub const Query = documents.Query;
pub const insert = Store.insert;
pub const get = Store.get;
pub const save = Store.save;
pub const set_status = Store.set_status;
pub const delete = Store.delete;
pub const rename = Store.rename;
pub const count_by_type = Store.count_by_type;
pub const list = Store.list;

/// How deep a hierarchy goes: a term at depth 16 has no children.
pub const depth_max: u32 = 16;
pub const tree_max: u32 = 10_000;

/// What a tree wants of every term of a taxonomy: identity, parent, status, and the live
/// title and slug. Field order is the column order of `select_nodes`.
pub const Node = struct {
    id: []const u8,
    parent_id: ?[]const u8,
    status: []const u8,
    title: []const u8,
    slug: ?[]const u8,
};

pub fn parent_of(connection: *db.Db, arena: std.mem.Allocator, id: []const u8) Error!?[]const u8 {
    std.debug.assert(id.len > 0);
    std.debug.assert(id.len <= 128);

    var select = try connection.prepare("SELECT parent_id FROM terms WHERE id = ?1");
    defer select.finalize();

    try select.bind_text(1, id);

    if (!try select.step()) {
        return error.NotFound;
    }

    const Found = struct { parent_id: ?[]const u8 };
    return (try select.read(Found, arena)).parent_id;
}

pub fn set_parent(connection: *db.Db, id: []const u8, parent_id: ?[]const u8) Error!void {
    std.debug.assert(id.len > 0);
    std.debug.assert(parent_id == null or !std.mem.eql(u8, parent_id.?, id));

    var statement = try connection.prepare("UPDATE terms SET parent_id = ?2 WHERE id = ?1");
    defer statement.finalize();

    try statement.bind_text(1, id);
    try statement.bind_optional_text(2, parent_id);
    try statement.exec();

    if (connection.changes() == 0) {
        return error.NotFound;
    }
}

/// The chain of parents above a term, nearest first, at most `depth_max` long.
pub fn ancestors(connection: *db.Db, arena: std.mem.Allocator, id: []const u8) Error![][]const u8 {
    std.debug.assert(id.len > 0);
    std.debug.assert(depth_max > 0);

    var select = try connection.prepare(
        "WITH RECURSIVE chain(id, depth) AS (SELECT parent_id, 1 FROM terms WHERE id = ?1 " ++
            "UNION ALL SELECT t.parent_id, chain.depth + 1 FROM terms t JOIN chain " ++
            "ON t.id = chain.id WHERE chain.depth < ?2) " ++
            "SELECT id FROM chain WHERE id IS NOT NULL ORDER BY depth",
    );
    defer select.finalize();

    try select.bind_text(1, id);
    try select.bind_int(2, depth_max);

    const Found = struct { id: []const u8 };
    var found: std.ArrayList([]const u8) = .empty;

    while (try select.step()) {
        std.debug.assert(found.items.len < depth_max);
        const row = try select.read(Found, arena);
        found.append(arena, row.id) catch return error.OutOfMemory;
    }

    return found.items;
}

pub fn has_children(connection: *db.Db, id: []const u8) Error!bool {
    std.debug.assert(id.len > 0);
    std.debug.assert(id.len <= 128);

    var select = try connection.prepare("SELECT 1 FROM terms WHERE parent_id = ?1 LIMIT 1");
    defer select.finalize();

    try select.bind_text(1, id);

    return try select.step();
}

const select_nodes = "SELECT r.id, r.parent_id, r.status, title.value, slug.value FROM terms r " ++
    "JOIN taxonomies t ON t.id = r.type_id " ++
    "LEFT JOIN term_values title ON title.record = r.id AND title.slot = 'live' " ++
    "AND title.ordinal = 0 AND title.field = json_extract(t.definition, '$.title_field') " ++
    "LEFT JOIN term_values slug ON slug.record = r.id AND slug.slot = 'live' " ++
    "AND slug.ordinal = 0 AND slug.field = (SELECT f.value ->> 'name' " ++
    "FROM field_groups g, json_each(g.definition, '$.fields') f " ++
    "WHERE g.scope = 'taxonomies' AND g.owner = t.id " ++
    "AND f.value ->> 'kind' = 'slug' LIMIT 1) " ++
    "WHERE r.type_id = ?1 ORDER BY title.value, r.id LIMIT ?2";

/// Every term of a taxonomy, by title; the tree is put together in `model/tree.zig`.
pub fn nodes(connection: *db.Db, arena: std.mem.Allocator, taxonomy_id: []const u8) Error![]Node {
    std.debug.assert(taxonomy_id.len > 0);
    std.debug.assert(tree_max > 0);

    var select = try connection.prepare(select_nodes);
    defer select.finalize();

    try select.bind_text(1, taxonomy_id);
    try select.bind_int(2, tree_max);

    var found: std.ArrayList(Node) = .empty;

    while (try select.step()) {
        std.debug.assert(found.items.len < tree_max);
        const row = try select.read(Node, arena);
        found.append(arena, row) catch return error.OutOfMemory;
    }

    return found.items;
}

fn seed_term(
    fixture: *db.testing.Fixture,
    arena: std.mem.Allocator,
    taxonomy_id: []const u8,
    name: []const u8,
    parent_id: ?[]const u8,
) ![]const u8 {
    const kinds = @import("../model/kinds.zig");
    const term_values = @import("term_values.zig");
    const id = try insert(&fixture.connection, std.testing.io, arena, .{
        .type_id = taxonomy_id,
        .created_by = null,
        .status = "published",
    }, 0);
    const template = "{{\"name\":\"{s}\",\"slug\":\"{s}\"}}";
    const text = try std.fmt.allocPrint(arena, template, .{ name, name });
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    const fields = taxonomy.test_topics.fields;

    const connection = &fixture.connection;

    try term_values.write(&kinds.core, connection, id, "live", taxonomy_id, fields, parsed);
    try set_parent(&fixture.connection, id, parent_id);

    return id;
}

test "terms: parents, ancestors, children and the node list of a taxonomy" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;
    const taxonomies = @import("taxonomies.zig");
    const taxonomy_id = try taxonomies.insert(connection, arena, taxonomy.test_topics, 0);

    const root = try seed_term(&fixture, arena, taxonomy_id, "a", null);
    const middle = try seed_term(&fixture, arena, taxonomy_id, "b", root);
    const leaf = try seed_term(&fixture, arena, taxonomy_id, "c", middle);

    try std.testing.expect((try parent_of(connection, arena, root)) == null);
    try std.testing.expectEqualStrings(middle, (try parent_of(connection, arena, leaf)).?);
    try std.testing.expectError(error.NotFound, parent_of(connection, arena, "missing"));
    try std.testing.expectError(error.NotFound, set_parent(connection, "missing", null));

    const chain = try ancestors(connection, arena, leaf);
    try std.testing.expectEqual(@as(usize, 2), chain.len);
    try std.testing.expectEqualStrings(middle, chain[0]);
    try std.testing.expectEqualStrings(root, chain[1]);
    try std.testing.expectEqual(@as(usize, 0), (try ancestors(connection, arena, root)).len);

    try std.testing.expect(try has_children(connection, root));
    try std.testing.expect(!try has_children(connection, leaf));

    const listed = try nodes(connection, arena, taxonomy_id);
    try std.testing.expectEqual(@as(usize, 3), listed.len);
    try std.testing.expectEqualStrings("a", listed[0].title);
    try std.testing.expectEqualStrings("a", listed[0].slug.?);
    try std.testing.expect(listed[0].parent_id == null);
    try std.testing.expectEqualStrings(root, listed[1].parent_id.?);

    const removal = delete(connection, root);
    try std.testing.expectError(error.Constraint, removal);
    try std.testing.expect(try delete(connection, leaf));
    try std.testing.expectEqual(@as(u32, 2), try count_by_type(connection, taxonomy_id));
}
