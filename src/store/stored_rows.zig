//! Anything a site stores, its rows put exactly as given and read back the same way: its own
//! row updated in place (what hangs from it stays), the rows hanging from it replaced whole,
//! derived search text cleared to be made again. Rows are JSON objects by column, as another
//! copy of the site keeps them; column names come from the schema, values are bound, a BLOB
//! travels as hex.

const std = @import("std");
const db = @import("../lib/db.zig");
const shapes = @import("stored_rows/shapes.zig");
const statements = @import("stored_rows/statements.zig");

pub const Kind = shapes.Kind;
pub const Outcome = shapes.Outcome;
pub const Table = shapes.Table;
pub const Shape = shapes.Shape;
pub const shape_of = shapes.shape_of;

/// Rows one unit holds in one table, at most.
pub const rows_max: u32 = 1 << 16;
pub const Error = statements.Error;

/// What a put did, and the unit's own row as JSON (as it is now, or as it was when removed;
/// empty when there was none).
pub const Put = struct {
    outcome: Outcome,
    own: []const u8,
};

/// The unit made exactly `rows` (`{"<table>":[{…}],…}`; `{}` removes it). Nothing is written
/// when it already holds them.
pub fn put(
    connection: *db.Db,
    arena: std.mem.Allocator,
    shape: Shape,
    id: []const u8,
    rows: []const u8,
) Error!Put {
    std.debug.assert(id.len > 0);
    std.debug.assert(connection.transaction_depth >= 1);

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, rows, .{
        .allocate = .alloc_always,
    }) catch return error.Invalid;

    if (parsed != .object) {
        return error.Invalid;
    }

    try check_tables(shape, parsed.object);

    const own_given = try rows_in(arena, parsed.object, shape.own.name);
    const own_before = try statements.canonical_stored(connection, arena, shape.own, id);

    if (try holds(connection, arena, shape, id, parsed.object)) {
        return .{
            .outcome = .unchanged,
            .own = if (std.mem.eql(u8, own_before, "[]")) "" else own_before,
        };
    }

    // Rows may name units written later in the same call: checked at commit.
    try connection.exec("PRAGMA defer_foreign_keys = ON");

    if (shape.derived) |derived| {
        try statements.clear(connection, arena, derived, id);
    }

    for (shape.children) |child| {
        try statements.clear(connection, arena, child, id);
    }

    if (std.mem.eql(u8, own_given, "[]")) {
        try statements.clear(connection, arena, shape.own, id);

        return .{
            .outcome = if (std.mem.eql(u8, own_before, "[]")) .unchanged else .removed,
            .own = if (std.mem.eql(u8, own_before, "[]")) "" else own_before,
        };
    }

    try statements.put_own(connection, arena, shape, id, own_given);

    for (shape.children) |child| {
        const given = try rows_in(arena, parsed.object, child.name);

        try statements.insert(connection, arena, child, id, given);
    }

    return .{
        .outcome = if (std.mem.eql(u8, own_before, "[]")) .added else .replaced,
        .own = try statements.canonical_stored(connection, arena, shape.own, id),
    };
}

/// The unit's stored rows by table, as `put` takes them; `{}` when it is not there.
pub fn read(
    connection: *db.Db,
    arena: std.mem.Allocator,
    shape: Shape,
    id: []const u8,
) Error![]const u8 {
    std.debug.assert(id.len > 0);
    std.debug.assert(shape.children.len <= 4);

    const own = try statements.canonical_stored(connection, arena, shape.own, id);

    if (std.mem.eql(u8, own, "[]")) {
        return "{}";
    }

    var out: std.ArrayList(u8) = .empty;

    try out.print(arena, "{{\"{s}\":{s}", .{ shape.own.name, own });

    for (shape.children) |child| {
        const found = try statements.canonical_stored(connection, arena, child, id);

        try out.print(arena, ",\"{s}\":{s}", .{ child.name, found });
    }

    try out.append(arena, '}');

    return out.items;
}

/// Whether the unit's own and hanging rows are already exactly those given.
fn holds(
    connection: *db.Db,
    arena: std.mem.Allocator,
    shape: Shape,
    id: []const u8,
    given: std.json.ObjectMap,
) Error!bool {
    std.debug.assert(id.len > 0);
    std.debug.assert(shape.own.name.len > 0);

    const own_given = try rows_in(arena, given, shape.own.name);
    const own_wanted = try statements.canonical_given(connection, arena, shape.own, id, own_given);
    const own_stored = try statements.canonical_stored(connection, arena, shape.own, id);

    if (!std.mem.eql(u8, own_wanted, own_stored)) {
        return false;
    }

    if (std.mem.eql(u8, own_given, "[]")) {
        return true;
    }

    for (shape.children) |child| {
        const child_given = try rows_in(arena, given, child.name);
        const wanted = try statements.canonical_given(connection, arena, child, id, child_given);
        const stored = try statements.canonical_stored(connection, arena, child, id);

        if (!std.mem.eql(u8, wanted, stored)) {
            return false;
        }
    }

    return true;
}

/// Only the shape's own tables, each a list.
fn check_tables(shape: Shape, given: std.json.ObjectMap) Error!void {
    std.debug.assert(shape.own.name.len > 0);

    var iterator = given.iterator();

    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        var known = std.mem.eql(u8, name, shape.own.name) or
            (shape.derived != null and std.mem.eql(u8, name, shape.derived.?.name));

        for (shape.children) |child| {
            known = known or std.mem.eql(u8, name, child.name);
        }

        if (!known or entry.value_ptr.* != .array) {
            return error.Invalid;
        }

        if (entry.value_ptr.array.items.len > rows_max) {
            return error.Invalid;
        }
    }
}

/// The table's rows as a JSON array text; `[]` when none are given.
fn rows_in(
    arena: std.mem.Allocator,
    given: std.json.ObjectMap,
    table: []const u8,
) Error![]const u8 {
    std.debug.assert(table.len > 0);

    const found = given.get(table) orelse return "[]";

    std.debug.assert(found == .array);

    if (found.array.items.len == 0) {
        return "[]";
    }

    return std.json.Stringify.valueAlloc(arena, found, .{}) catch error.OutOfMemory;
}

fn outcome_of(
    connection: *db.Db,
    arena: std.mem.Allocator,
    shape: Shape,
    rows: []const u8,
) Error!Outcome {
    std.debug.assert(rows.len > 0);

    return (try put(connection, arena, shape, "t1", rows)).outcome;
}

test "a unit's rows put exactly, read back the same, unchanged twice, then removed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const connection = &fixture.connection;
    const shape: Shape = .{
        .own = .{
            .name = "notes",
            .key = "id",
        },
        .conflict = "id",
        .children = &.{.{
            .name = "groups",
            .key = "owner",
            .scope = "notes",
        }},
        .derived = .{
            .name = "note_search",
            .key = "record",
        },
    };

    try connection.exec("CREATE TABLE notes (id TEXT PRIMARY KEY, status TEXT NOT NULL, " ++
        "token BLOB) STRICT");
    try connection.exec("CREATE TABLE groups (scope TEXT NOT NULL, owner TEXT NOT NULL, " ++
        "count ANY NOT NULL, PRIMARY KEY (scope, owner)) STRICT");
    try connection.exec("CREATE TABLE note_search (record TEXT, text TEXT)");
    try connection.exec("INSERT INTO notes VALUES ('t1', 'draft', NULL)");
    try connection.exec("INSERT INTO groups VALUES ('notes', 't1', 1), ('other', 't1', 9)");
    try connection.exec("INSERT INTO note_search VALUES ('t1', 'old')");

    var transaction = try connection.transaction();
    defer transaction.rollback();

    const given =
        \\{"notes":[{"id":"x","status":"published","token":"0A0B"}],
        \\ "groups":[{"scope":"x","owner":"other","count":3}],"note_search":[]}
    ;
    const first = try put(connection, arena, shape, "t1", given);

    try std.testing.expectEqual(Outcome.replaced, first.outcome);

    const kept = try read(connection, arena, shape, "t1");

    try std.testing.expectEqualStrings("{\"notes\":[{\"id\":\"t1\",\"status\":\"published\"," ++
        "\"token\":\"0A0B\"}],\"groups\":[{\"scope\":\"notes\",\"owner\":\"t1\"," ++
        "\"count\":3}]}", kept);
    try std.testing.expectEqual(Outcome.unchanged, try outcome_of(connection, arena, shape, given));
    try std.testing.expectEqual(Outcome.unchanged, try outcome_of(connection, arena, shape, kept));

    try std.testing.expectError(error.Invalid, put(connection, arena, shape, "t1", "{\"x\":[]}"));
    try std.testing.expectError(error.Invalid, put(connection, arena, shape, "t1",
        \\{"notes":[{"id":"t1","status":"a"},{"id":"t1","status":"b"}]}
    ));

    const removed = try put(connection, arena, shape, "t1", "{}");

    try std.testing.expectEqual(Outcome.removed, removed.outcome);
    try std.testing.expectEqualStrings("{}", try read(connection, arena, shape, "t1"));
    try std.testing.expectEqual(Outcome.unchanged, try outcome_of(connection, arena, shape, "{}"));
    try std.testing.expectEqual(Outcome.added, try outcome_of(connection, arena, shape, kept));
    try std.testing.expectEqualStrings(kept, try read(connection, arena, shape, "t1"));

    // Another scope's row, and the search text, are not the unit's.
    var count = try connection.prepare("SELECT (SELECT count(*) FROM groups WHERE scope = " ++
        "'other') + 10 * (SELECT count(*) FROM note_search) AS seen");
    defer count.finalize();

    const Seen = struct {
        seen: i64,
    };

    try std.testing.expect(try count.step());
    try std.testing.expectEqual(@as(i64, 1), (try count.read(Seen, arena)).seen);
}
