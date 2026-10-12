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
pub const count = Store.count;

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

    const Found = struct {
        parent_id: ?[]const u8,
    };
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

    const Found = struct {
        id: []const u8,
    };
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

const nodes_from = "FROM terms r " ++
    "JOIN taxonomies t ON t.id = r.type_id " ++
    "LEFT JOIN term_values title ON title.record = r.id AND title.slot = 'live' " ++
    "AND title.ordinal = 0 AND title.field = json_extract(t.definition, '$.title_field') " ++
    "LEFT JOIN term_values slug ON slug.record = r.id AND slug.slot = 'live' " ++
    "AND slug.ordinal = 0 AND slug.field = (SELECT f.value ->> 'name' " ++
    "FROM field_groups g, json_each(g.definition, '$.fields') f " ++
    "WHERE g.scope = 'taxonomies' AND g.owner = t.id " ++
    "AND f.value ->> 'kind' = 'slug' LIMIT 1) ";

/// A taxonomy's terms shown (`?2`: a JSON array of the statuses shown, every one when
/// empty) placed in tree order: a parent before its children, siblings by title, a term
/// whose parent is not shown at the root, at most `depth_max` deep. Each with its depth,
/// and its path, which sorts in that order.
const placed_terms = "WITH RECURSIVE shown AS (SELECT r.id AS id, r.parent_id AS parent_id, " ++
    "r.status AS status, coalesce(title.value, '') AS title, slug.value AS slug " ++ nodes_from ++
    "WHERE r.type_id = ?1 AND (?2 = '' OR r.status IN (SELECT value FROM json_each(?2)))), " ++
    "placed(id, parent_id, status, title, slug, depth, path) AS (" ++
    "SELECT id, parent_id, status, title, slug, 0, title || char(31) || id FROM shown " ++
    "WHERE parent_id IS NULL OR parent_id = id OR parent_id NOT IN (SELECT id FROM shown) " ++
    "UNION ALL SELECT c.id, c.parent_id, c.status, c.title, c.slug, p.depth + 1, " ++
    "p.path || char(30) || c.title || char(31) || c.id FROM shown c " ++
    "JOIN placed p ON c.parent_id = p.id WHERE c.parent_id <> c.id AND p.depth < " ++
    std.fmt.comptimePrint("{d}", .{depth_max}) ++ ") ";

/// A term as a page of its taxonomy's tree shows it.
pub const Placed = struct {
    id: []const u8,
    parent_id: ?[]const u8,
    status: []const u8,
    title: []const u8,
    slug: ?[]const u8,
    depth: i64,
};

/// Which of a taxonomy's terms a page of its tree reads: those of `statuses_json` (a JSON
/// array; every status when empty), `limit` of them from `offset`, in tree order.
pub const Window = struct {
    statuses_json: []const u8 = "",
    offset: u32 = 0,
    limit: u32,
};

pub fn tree_page(
    connection: *db.Db,
    arena: std.mem.Allocator,
    taxonomy_id: []const u8,
    window: Window,
) Error![]Placed {
    std.debug.assert(taxonomy_id.len > 0);
    std.debug.assert(window.limit > 0 and window.limit <= tree_max);

    var select = try connection.prepare(placed_terms ++
        "SELECT id, parent_id, status, title, slug, depth FROM placed ORDER BY path " ++
        "LIMIT ?3 OFFSET ?4");
    defer select.finalize();

    try select.bind_text(1, taxonomy_id);
    try select.bind_text(2, window.statuses_json);
    try select.bind_int(3, window.limit);
    try select.bind_int(4, window.offset);

    var found: std.ArrayList(Placed) = .empty;

    while (try select.step()) {
        std.debug.assert(found.items.len < window.limit);
        const row = try select.read(Placed, arena);
        found.append(arena, row) catch return error.OutOfMemory;
    }

    return found.items;
}

/// How many terms the tree places, as `tree_page` reads them.
pub fn tree_count(
    connection: *db.Db,
    taxonomy_id: []const u8,
    statuses_json: []const u8,
) Error!u32 {
    std.debug.assert(taxonomy_id.len > 0);
    std.debug.assert(statuses_json.len <= 4096);

    var select = try connection.prepare(placed_terms ++ "SELECT count(*) FROM placed");
    defer select.finalize();

    try select.bind_text(1, taxonomy_id);
    try select.bind_text(2, statuses_json);

    std.debug.assert(try select.step());

    return @intCast(select.read_int());
}

/// Where a term named so is looked for: anywhere in its taxonomy, at the root, or under a
/// parent.
pub const Under = union(enum) {
    anywhere,
    root,
    parent: []const u8,
};

/// The id of the term of `taxonomy_id` titled `name` (ASCII case aside) where `under`
/// says, the oldest when several are; null when none is.
pub fn find_named(
    connection: *db.Db,
    arena: std.mem.Allocator,
    taxonomy_id: []const u8,
    under: Under,
    name: []const u8,
) Error!?[]const u8 {
    std.debug.assert(taxonomy_id.len > 0);
    std.debug.assert(name.len > 0 and name.len <= 1024);

    var select = try connection.prepare("SELECT r.id " ++ nodes_from ++
        "WHERE r.type_id = ?1 AND lower(title.value) = lower(?2) AND " ++
        "(?3 = 'anywhere' OR (?3 = 'root' AND r.parent_id IS NULL) OR " ++
        "(?3 = 'parent' AND r.parent_id = ?4)) ORDER BY r.id LIMIT 1");
    defer select.finalize();

    try select.bind_text(1, taxonomy_id);
    try select.bind_text(2, name);
    try select.bind_text(3, @tagName(under));
    try select.bind_text(4, if (under == .parent) under.parent else "");

    if (!try select.step()) {
        return null;
    }

    const Found = struct {
        id: []const u8,
    };

    return (try select.read(Found, arena)).id;
}

/// One term of a taxonomy as a tree shows it; null when the taxonomy has none such.
pub fn node(
    connection: *db.Db,
    arena: std.mem.Allocator,
    taxonomy_id: []const u8,
    id: []const u8,
) Error!?Node {
    std.debug.assert(id.len > 0 and id.len <= 128);
    std.debug.assert(taxonomy_id.len > 0);

    var select = try connection.prepare(
        "SELECT r.id, r.parent_id, r.status, coalesce(title.value, ''), slug.value " ++
            nodes_from ++ "WHERE r.id = ?1 AND r.type_id = ?2",
    );
    defer select.finalize();

    try select.bind_text(1, id);
    try select.bind_text(2, taxonomy_id);

    if (!try select.step()) {
        return null;
    }

    return try select.read(Node, arena);
}

/// The ids of the first `limit` children of a term, oldest first.
pub fn child_ids(
    connection: *db.Db,
    arena: std.mem.Allocator,
    parent_id: []const u8,
    limit: u32,
) Error![]const []const u8 {
    std.debug.assert(parent_id.len > 0);
    std.debug.assert(limit > 0 and limit <= tree_max);

    var select = try connection.prepare(
        "SELECT id FROM terms WHERE parent_id = ?1 AND id <> ?1 ORDER BY id LIMIT ?2",
    );
    defer select.finalize();

    try select.bind_text(1, parent_id);
    try select.bind_int(2, limit);

    const Found = struct {
        id: []const u8,
    };
    var found: std.ArrayList([]const u8) = .empty;

    while (try select.step()) {
        std.debug.assert(found.items.len < limit);
        const row = try select.read(Found, arena);
        found.append(arena, row.id) catch return error.OutOfMemory;
    }

    return found.items;
}

/// Whether any term of a taxonomy has a parent.
pub fn any_parented(connection: *db.Db, taxonomy_id: []const u8) Error!bool {
    std.debug.assert(taxonomy_id.len > 0);
    std.debug.assert(taxonomy_id.len <= 128);

    var select = try connection.prepare(
        "SELECT 1 FROM terms WHERE type_id = ?1 AND parent_id IS NOT NULL LIMIT 1",
    );
    defer select.finalize();

    try select.bind_text(1, taxonomy_id);

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

test "terms: a page of the tree in order, a hidden parent's child at the root, lookups" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;
    const taxonomies = @import("taxonomies.zig");
    const taxonomy_id = try taxonomies.insert(connection, arena, taxonomy.test_topics, 0);

    const beta = try seed_term(&fixture, arena, taxonomy_id, "b", null);
    const alpha = try seed_term(&fixture, arena, taxonomy_id, "a", null);
    const alpha_two = try seed_term(&fixture, arena, taxonomy_id, "a2", alpha);
    _ = try seed_term(&fixture, arena, taxonomy_id, "a1", alpha);
    const zeta = try seed_term(&fixture, arena, taxonomy_id, "z", beta);

    const all = try tree_page(connection, arena, taxonomy_id, .{
        .limit = 10,
    });
    const order = [_][]const u8{ "a", "a1", "a2", "b", "z" };
    const depths = [_]i64{ 0, 1, 1, 0, 1 };

    try std.testing.expectEqual(order.len, all.len);

    for (all, order, depths) |placed, title, depth| {
        try std.testing.expectEqualStrings(title, placed.title);
        try std.testing.expectEqual(depth, placed.depth);
    }

    const middle = try tree_page(connection, arena, taxonomy_id, .{
        .offset = 1,
        .limit = 2,
    });
    try std.testing.expectEqualStrings("a1", middle[0].title);
    try std.testing.expectEqualStrings("a2", middle[1].title);
    try std.testing.expectEqual(5, try tree_count(connection, taxonomy_id, ""));

    var hide = try connection.prepare("UPDATE terms SET status = 'draft' WHERE id = ?1");
    defer hide.finalize();
    try hide.bind_text(1, beta);
    try hide.exec();

    const live = try tree_page(connection, arena, taxonomy_id, .{
        .statuses_json = "[\"published\"]",
        .limit = 10,
    });
    try std.testing.expectEqual(4, live.len);
    try std.testing.expectEqualStrings(zeta, live[3].id);
    try std.testing.expectEqual(0, live[3].depth);
    try std.testing.expectEqual(4, try tree_count(connection, taxonomy_id, "[\"published\"]"));

    const named = try find_named(connection, arena, taxonomy_id, .anywhere, "A");
    try std.testing.expectEqualStrings(alpha, named.?);
    try std.testing.expectEqualStrings(alpha_two, (try find_named(connection, arena, taxonomy_id, .{
        .parent = alpha,
    }, "A2")).?);
    try std.testing.expectEqual(null, try find_named(connection, arena, taxonomy_id, .root, "z"));
    try std.testing.expect(try any_parented(connection, taxonomy_id));
    try std.testing.expectEqual(2, (try child_ids(connection, arena, alpha, 10)).len);
    const found = try node(connection, arena, taxonomy_id, alpha_two);
    try std.testing.expectEqualStrings("a2", found.?.title);
    try std.testing.expectEqual(null, try node(connection, arena, "other", alpha_two));
}
