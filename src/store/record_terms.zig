//! The `record_terms` table: which terms a record is assigned to, per slot and field,
//! every ancestor included. The explicit selections come from the document; the
//! ancestors from `terms.parent_id`.

const std = @import("std");
const db = @import("../lib/db.zig");
const terms = @import("terms.zig");

pub const WriteError = db.Error || error{Invalid};
pub const Error = WriteError || error{Conflict};
pub const ids_max: u32 = 64;
/// Most (record, slot, field) assignments one reparenting may rebuild.
pub const rebuild_max: u32 = 10_000;
pub const members_max: u32 = 1000;

/// One assignment of the document: the explicit terms of one field in one slot.
pub const Assignment = struct { record: []const u8, slot: []const u8, field: []const u8 };

/// Replace one field's assignments in a slot: the ids given, and every ancestor of each.
pub fn write(
    connection: *db.Db,
    assignment: Assignment,
    term_ids: []const []const u8,
) WriteError!void {
    std.debug.assert(assignment.record.len > 0);
    std.debug.assert(assignment.field.len > 0);

    if (term_ids.len > ids_max) {
        return error.Invalid;
    }

    try clear_field(connection, assignment);

    var insert = try connection.prepare(
        "INSERT INTO record_terms (record, slot, field, term, ordinal, explicit) " ++
            "WITH RECURSIVE chain(term, depth) AS (SELECT ?4, 0 UNION ALL " ++
            "SELECT t.parent_id, chain.depth + 1 FROM terms t JOIN chain ON t.id = chain.term " ++
            "WHERE t.parent_id IS NOT NULL AND chain.depth < ?6) " ++
            "SELECT ?1, ?2, ?3, term, CASE WHEN depth = 0 THEN ?5 ELSE 0 END, depth = 0 " ++
            "FROM chain WHERE term IN (SELECT id FROM terms) " ++
            "ON CONFLICT (record, slot, field, term) DO UPDATE SET " ++
            "explicit = max(explicit, excluded.explicit), " ++
            "ordinal = CASE WHEN excluded.explicit THEN excluded.ordinal ELSE ordinal END",
    );
    defer insert.finalize();

    for (term_ids, 0..) |term_id, ordinal| {
        insert.reset();
        try insert.bind_text(1, assignment.record);
        try insert.bind_text(2, assignment.slot);
        try insert.bind_text(3, assignment.field);
        try insert.bind_text(4, term_id);
        try insert.bind_int(5, @intCast(ordinal));
        try insert.bind_int(6, terms.depth_max);
        try insert.exec();
    }
}

fn clear_field(connection: *db.Db, assignment: Assignment) db.Error!void {
    std.debug.assert(assignment.record.len > 0);
    std.debug.assert(assignment.slot.len > 0);

    var statement = try connection.prepare(
        "DELETE FROM record_terms WHERE record = ?1 AND slot = ?2 AND field = ?3",
    );
    defer statement.finalize();

    try statement.bind_text(1, assignment.record);
    try statement.bind_text(2, assignment.slot);
    try statement.bind_text(3, assignment.field);
    try statement.exec();
}

/// Every assignment of a record in a slot, or in every slot when none is named.
pub fn clear(connection: *db.Db, record_id: []const u8, slot: ?[]const u8) db.Error!void {
    std.debug.assert(record_id.len > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    var statement = try connection.prepare(
        "DELETE FROM record_terms WHERE record = ?1 AND (?2 IS NULL OR slot = ?2)",
    );
    defer statement.finalize();

    try statement.bind_text(1, record_id);
    try statement.bind_optional_text(2, slot);
    try statement.exec();
}

/// The assignments of one slot take the name of another, whose own go.
pub fn promote(
    connection: *db.Db,
    record_id: []const u8,
    from: []const u8,
    to: []const u8,
) db.Error!void {
    std.debug.assert(record_id.len > 0);
    std.debug.assert(!std.mem.eql(u8, from, to));

    try clear(connection, record_id, to);

    var statement = try connection.prepare(
        "UPDATE record_terms SET slot = ?3 WHERE record = ?1 AND slot = ?2",
    );
    defer statement.finalize();

    try statement.bind_text(1, record_id);
    try statement.bind_text(2, from);
    try statement.bind_text(3, to);
    try statement.exec();
}

pub fn rename(connection: *db.Db, from: []const u8, to: []const u8) db.Error!void {
    std.debug.assert(from.len > 0);
    std.debug.assert(to.len > 0);

    var statement = try connection.prepare(
        "UPDATE record_terms SET record = ?1 WHERE record = ?2",
    );
    defer statement.finalize();

    try statement.bind_text(1, to);
    try statement.bind_text(2, from);
    try statement.exec();
}

/// Every assignment of one field across the records of a type: how many rows went.
pub fn delete_field(connection: *db.Db, type_id: []const u8, field: []const u8) db.Error!u32 {
    std.debug.assert(type_id.len > 0);
    std.debug.assert(field.len > 0);

    var statement = try connection.prepare(
        "DELETE FROM record_terms WHERE field = ?2 " ++
            "AND record IN (SELECT id FROM records WHERE type_id = ?1)",
    );
    defer statement.finalize();

    try statement.bind_text(1, type_id);
    try statement.bind_text(2, field);
    try statement.exec();

    return connection.changes();
}

/// How many live assignments name a term, explicitly or through a descendant.
pub fn assigned_count(connection: *db.Db, term_id: []const u8) db.Error!u32 {
    std.debug.assert(term_id.len > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    var select = try connection.prepare(
        "SELECT count(*) FROM record_terms WHERE term = ?1 AND slot = 'live'",
    );
    defer select.finalize();

    try select.bind_text(1, term_id);

    std.debug.assert(try select.step());

    return @intCast(select.read_int());
}

/// The records in a term (live slot), ancestors' members included.
pub fn members(
    connection: *db.Db,
    arena: std.mem.Allocator,
    term_id: []const u8,
) db.Error![][]const u8 {
    std.debug.assert(term_id.len > 0);
    std.debug.assert(members_max > 0);

    var select = try connection.prepare(
        "SELECT DISTINCT record FROM record_terms WHERE term = ?1 AND slot = 'live' " ++
            "ORDER BY record LIMIT ?2",
    );
    defer select.finalize();

    try select.bind_text(1, term_id);
    try select.bind_int(2, members_max);

    const Found = struct { record: []const u8 };
    var found: std.ArrayList([]const u8) = .empty;

    while (try select.step()) {
        std.debug.assert(found.items.len < members_max);
        const row = try select.read(Found, arena);
        found.append(arena, row.record) catch return error.OutOfMemory;
    }

    return found.items;
}

/// After a term moved under another parent: every assignment that includes it is written
/// again from its explicit terms, so ancestors follow the new hierarchy. Refused while
/// more than `rebuild_max` assignments would have to change.
pub fn rebuild(connection: *db.Db, arena: std.mem.Allocator, term_id: []const u8) Error!u32 {
    std.debug.assert(term_id.len > 0);
    std.debug.assert(rebuild_max > 0);

    const affected = try assignments_of(connection, arena, term_id);

    for (affected) |assignment| {
        const explicit = try explicit_of(connection, arena, assignment);

        try write(connection, assignment, explicit);
    }

    return @intCast(affected.len);
}

fn assignments_of(
    connection: *db.Db,
    arena: std.mem.Allocator,
    term_id: []const u8,
) Error![]Assignment {
    std.debug.assert(term_id.len > 0);
    std.debug.assert(rebuild_max > 0);

    var select = try connection.prepare(
        "SELECT DISTINCT record, slot, field FROM record_terms WHERE term = ?1 " ++
            "ORDER BY record, slot, field LIMIT ?2",
    );
    defer select.finalize();

    try select.bind_text(1, term_id);
    try select.bind_int(2, rebuild_max + 1);

    var found: std.ArrayList(Assignment) = .empty;

    while (try select.step()) {
        if (found.items.len == rebuild_max) {
            return error.Conflict;
        }

        const row = try select.read(Assignment, arena);
        found.append(arena, row) catch return error.OutOfMemory;
    }

    return found.items;
}

fn explicit_of(
    connection: *db.Db,
    arena: std.mem.Allocator,
    assignment: Assignment,
) WriteError![][]const u8 {
    std.debug.assert(assignment.record.len > 0);
    std.debug.assert(ids_max > 0);

    var select = try connection.prepare(
        "SELECT term FROM record_terms WHERE record = ?1 AND slot = ?2 AND field = ?3 " ++
            "AND explicit = 1 ORDER BY ordinal LIMIT ?4",
    );
    defer select.finalize();

    try select.bind_text(1, assignment.record);
    try select.bind_text(2, assignment.slot);
    try select.bind_text(3, assignment.field);
    try select.bind_int(4, ids_max);

    const Found = struct { term: []const u8 };
    var found: std.ArrayList([]const u8) = .empty;

    while (try select.step()) {
        std.debug.assert(found.items.len < ids_max);
        const row = try select.read(Found, arena);
        found.append(arena, row.term) catch return error.OutOfMemory;
    }

    return found.items;
}

const Row = struct { term: []const u8, explicit: bool, ordinal: i64 };

fn rows_of(connection: *db.Db, arena: std.mem.Allocator, assignment: Assignment) ![]Row {
    std.debug.assert(assignment.record.len > 0);
    std.debug.assert(assignment.field.len > 0);

    var select = try connection.prepare(
        "SELECT term, explicit, ordinal FROM record_terms WHERE record = ?1 AND slot = ?2 " ++
            "AND field = ?3 ORDER BY explicit DESC, ordinal, term",
    );
    defer select.finalize();

    try select.bind_text(1, assignment.record);
    try select.bind_text(2, assignment.slot);
    try select.bind_text(3, assignment.field);

    var found: std.ArrayList(Row) = .empty;

    while (try select.step()) {
        try found.append(arena, try select.read(Row, arena));
    }

    return found.items;
}

const Seeded = struct {
    record: []const u8,
    root: []const u8,
    middle: []const u8,
    leaf: []const u8,
    aside: []const u8,
};

fn seed(fixture: *db.testing.Fixture, arena: std.mem.Allocator) !Seeded {
    std.debug.assert(fixture.connection.transaction_depth == 0);
    std.debug.assert(ids_max > 0);

    const taxonomy = @import("../model/taxonomy.zig");
    const content_type = @import("../model/content_type.zig");
    const taxonomies = @import("taxonomies.zig");
    const content_types = @import("content_types.zig");
    const records = @import("records.zig");
    const connection = &fixture.connection;
    const taxonomy_id = try taxonomies.insert(connection, arena, taxonomy.test_topics, 0);
    const type_id = try content_types.insert(connection, arena, content_type.test_post, 0);
    const record = try records.insert(connection, std.testing.io, arena, .{
        .type_id = type_id,
        .created_by = null,
        .status = "draft",
    }, 0);
    var ids: [4][]const u8 = undefined;

    for (&ids) |*id| {
        id.* = try terms.insert(connection, std.testing.io, arena, .{
            .type_id = taxonomy_id,
            .created_by = null,
            .status = "published",
        }, 0);
    }

    try terms.set_parent(connection, ids[1], ids[0]);
    try terms.set_parent(connection, ids[2], ids[1]);

    return .{ .record = record, .root = ids[0], .middle = ids[1], .leaf = ids[2], .aside = ids[3] };
}

test "an assignment holds the explicit terms and every ancestor; a rewrite replaces it" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;
    const seeded = try seed(&fixture, arena);
    const assignment: Assignment = .{ .record = seeded.record, .slot = "live", .field = "topics" };

    try write(connection, assignment, &.{ seeded.leaf, seeded.aside });

    const rows = try rows_of(connection, arena, assignment);
    try std.testing.expectEqual(@as(usize, 4), rows.len);
    try std.testing.expectEqualStrings(seeded.leaf, rows[0].term);
    try std.testing.expect(rows[0].explicit);
    try std.testing.expectEqualStrings(seeded.aside, rows[1].term);
    try std.testing.expectEqual(@as(i64, 1), rows[1].ordinal);
    try std.testing.expect(!rows[2].explicit and !rows[3].explicit);
    try std.testing.expectEqual(@as(u32, 1), try assigned_count(connection, seeded.root));
    try std.testing.expectEqual(@as(usize, 1), (try members(connection, arena, seeded.middle)).len);

    try write(connection, assignment, &.{seeded.root});
    const fewer = try rows_of(connection, arena, assignment);
    try std.testing.expectEqual(@as(usize, 1), fewer.len);
    try std.testing.expect(fewer[0].explicit);

    try write(connection, assignment, &.{"nope"});
    try std.testing.expectEqual(@as(usize, 0), (try rows_of(connection, arena, assignment)).len);

    var too_many: [ids_max + 1][]const u8 = undefined;
    @memset(&too_many, seeded.root);
    try std.testing.expectError(error.Invalid, write(connection, assignment, &too_many));
}

test "a selected ancestor stays explicit; slots promote and clear; a reparent rebuilds" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;
    const seeded = try seed(&fixture, arena);
    const pending: Assignment = .{ .record = seeded.record, .slot = "pending", .field = "topics" };
    const live: Assignment = .{ .record = seeded.record, .slot = "live", .field = "topics" };

    try write(connection, pending, &.{ seeded.leaf, seeded.root });
    const rows = try rows_of(connection, arena, pending);
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expect(rows[0].explicit and rows[1].explicit and !rows[2].explicit);
    try std.testing.expectEqual(@as(u32, 0), try assigned_count(connection, seeded.root));

    try promote(connection, seeded.record, "pending", "live");
    try std.testing.expectEqual(@as(usize, 0), (try rows_of(connection, arena, pending)).len);
    try std.testing.expectEqual(@as(usize, 3), (try rows_of(connection, arena, live)).len);

    try terms.set_parent(connection, seeded.leaf, seeded.aside);
    try std.testing.expectEqual(@as(u32, 1), try rebuild(connection, arena, seeded.leaf));
    const rebuilt = try rows_of(connection, arena, live);
    try std.testing.expectEqual(@as(usize, 3), rebuilt.len);
    try std.testing.expectEqualStrings(seeded.aside, rebuilt[2].term);
    try std.testing.expectEqual(@as(u32, 0), try assigned_count(connection, seeded.middle));

    try clear(connection, seeded.record, null);
    try std.testing.expectEqual(@as(u32, 0), try assigned_count(connection, seeded.root));
    try std.testing.expectEqual(@as(usize, 0), (try rows_of(connection, arena, live)).len);
}
