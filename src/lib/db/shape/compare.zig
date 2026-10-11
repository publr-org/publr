const std = @import("std");
const shape_module = @import("../shape.zig");

const Shape = shape_module.Shape;
const Table = shape_module.Table;
const Column = shape_module.Column;
const Object = shape_module.Object;

/// One way the live database differs from the shape this release expects.
pub const Difference = struct {
    /// `users`, `users.role`, `index records_slug`.
    subject: []const u8,
    change: Change,
    /// What this release expects, and what the database has, as words.
    expected: []const u8,
    live: []const u8,
    /// Whether this release still runs on it: something a newer release added that this one
    /// may ignore, or a rule the database holds more loosely than this release would.
    compatible: bool,

    pub const Change = enum { missing, extra, differs };
};

pub fn compare(arena: std.mem.Allocator, expected: Shape, live: Shape) ![]const Difference {
    std.debug.assert(expected.tables.len <= shape_module.tables_max);
    std.debug.assert(live.tables.len <= shape_module.tables_max);

    var differences: std.ArrayList(Difference) = .empty;

    for (expected.tables) |table| {
        if (live.table(table.name)) |found| {
            try compare_table(arena, &differences, table, found);
        } else {
            try differences.append(arena, .{
                .subject = table.name,
                .change = .missing,
                .expected = "a table",
                .live = "none",
                .compatible = false,
            });
        }
    }

    for (live.tables) |table| {
        if (expected.table(table.name) == null) {
            try differences.append(arena, .{
                .subject = table.name,
                .change = .extra,
                .expected = "none",
                .live = "a table",
                .compatible = true,
            });
        }
    }

    try compare_objects(arena, &differences, expected.objects, live.objects);

    return differences.items;
}

fn compare_table(
    arena: std.mem.Allocator,
    differences: *std.ArrayList(Difference),
    expected: Table,
    live: Table,
) !void {
    std.debug.assert(std.mem.eql(u8, expected.name, live.name));
    std.debug.assert(expected.columns.len <= shape_module.columns_max);

    if (expected.virtual_sql != null or live.virtual_sql != null) {
        const same = expected.virtual_sql != null and live.virtual_sql != null and
            std.mem.eql(u8, expected.virtual_sql.?, live.virtual_sql.?);

        if (!same) {
            try differences.append(arena, .{
                .subject = expected.name,
                .change = .differs,
                .expected = expected.virtual_sql orelse "a plain table",
                .live = live.virtual_sql orelse "a plain table",
                .compatible = false,
            });
        }

        return;
    }

    for (expected.columns) |column| {
        const subject = try std.fmt.allocPrint(arena, "{s}.{s}", .{ expected.name, column.name });

        if (column_of(live, column.name)) |found| {
            if (try column_difference(arena, subject, column, found)) |difference| {
                try differences.append(arena, difference);
            }
        } else {
            try differences.append(arena, .{
                .subject = subject,
                .change = .missing,
                .expected = try describe(arena, column),
                .live = "none",
                .compatible = false,
            });
        }
    }

    for (live.columns) |column| {
        if (column_of(expected, column.name) == null) {
            // This release inserts without it: only a column it may leave out is harmless.
            try differences.append(arena, .{
                .subject = try std.fmt.allocPrint(arena, "{s}.{s}", .{ live.name, column.name }),
                .change = .extra,
                .expected = "none",
                .live = try describe(arena, column),
                .compatible = !column.not_null or column.default != null,
            });
        }
    }

    try compare_rules(arena, differences, expected.name, expected.references, live.references);
    try compare_rules(arena, differences, expected.name, expected.uniques, live.uniques);
}

fn column_difference(
    arena: std.mem.Allocator,
    subject: []const u8,
    expected: Column,
    live: Column,
) !?Difference {
    std.debug.assert(subject.len > 0);
    std.debug.assert(std.mem.eql(u8, expected.name, live.name));

    const same_type = std.ascii.eqlIgnoreCase(expected.type_name, live.type_name);
    const same_default = optional_equal(expected.default, live.default);
    const same = same_type and same_default and expected.not_null == live.not_null and
        expected.primary == live.primary;

    if (same) {
        return null;
    }

    // Looser in the database than here: a NOT NULL dropped, a default added. This release
    // still writes every value it means to; it may only read a NULL it never wrote.
    const looser = same_type and expected.primary == live.primary and
        (!live.not_null or expected.not_null) and
        (expected.default == null or same_default);

    return .{
        .subject = subject,
        .change = .differs,
        .expected = try describe(arena, expected),
        .live = try describe(arena, live),
        .compatible = looser,
    };
}

/// References and uniquenesses: one the database lacks is looser (compatible), one only the
/// database has is stricter than this release knows (not).
fn compare_rules(
    arena: std.mem.Allocator,
    differences: *std.ArrayList(Difference),
    table: []const u8,
    expected: []const []const u8,
    live: []const []const u8,
) !void {
    std.debug.assert(table.len > 0);
    std.debug.assert(expected.len <= shape_module.columns_max);

    for (expected) |rule| {
        if (!contains(live, rule)) {
            try differences.append(arena, .{
                .subject = table,
                .change = .missing,
                .expected = rule,
                .live = "none",
                .compatible = true,
            });
        }
    }

    for (live) |rule| {
        if (!contains(expected, rule)) {
            try differences.append(arena, .{
                .subject = table,
                .change = .extra,
                .expected = "none",
                .live = rule,
                .compatible = false,
            });
        }
    }
}

fn compare_objects(
    arena: std.mem.Allocator,
    differences: *std.ArrayList(Difference),
    expected: []const Object,
    live: []const Object,
) !void {
    std.debug.assert(expected.len <= shape_module.objects_max);
    std.debug.assert(live.len <= shape_module.objects_max);

    for (expected) |object| {
        const subject = try std.fmt.allocPrint(arena, "{t} {s}", .{ object.kind, object.name });
        const found = object_of(live, object.name);

        if (found == null or !std.mem.eql(u8, found.?.sql, object.sql)) {
            try differences.append(arena, .{
                .subject = subject,
                .change = if (found == null) .missing else .differs,
                .expected = object.sql,
                .live = if (found) |other| other.sql else "none",
                .compatible = false,
            });
        }
    }

    for (live) |object| {
        if (object_of(expected, object.name) == null) {
            // A newer release's plain index or trigger; a uniqueness would refuse rows this
            // release writes.
            const unique = std.mem.startsWith(u8, object.sql, "CREATE UNIQUE");

            try differences.append(arena, .{
                .subject = try std.fmt.allocPrint(arena, "{t} {s}", .{ object.kind, object.name }),
                .change = .extra,
                .expected = "none",
                .live = object.sql,
                .compatible = !unique,
            });
        }
    }
}

fn describe(arena: std.mem.Allocator, column: Column) ![]const u8 {
    std.debug.assert(column.name.len > 0);
    std.debug.assert(column.primary >= 0);

    const type_name = if (column.type_name.len == 0) "(no type)" else column.type_name;
    const not_null = if (column.not_null) " NOT NULL" else "";
    const default_word = if (column.default != null) " DEFAULT " else "";
    const primary = if (column.primary > 0) " PRIMARY KEY" else "";

    return std.fmt.allocPrint(arena, "{s}{s}{s}{s}{s}", .{
        type_name,
        not_null,
        default_word,
        column.default orelse "",
        primary,
    });
}

fn column_of(table: Table, name: []const u8) ?Column {
    std.debug.assert(name.len > 0);
    std.debug.assert(table.columns.len <= shape_module.columns_max);

    for (table.columns) |column| {
        if (std.mem.eql(u8, column.name, name)) {
            return column;
        }
    }

    return null;
}

fn object_of(objects: []const Object, name: []const u8) ?Object {
    std.debug.assert(name.len > 0);
    std.debug.assert(objects.len <= shape_module.objects_max);

    for (objects) |object| {
        if (std.mem.eql(u8, object.name, name)) {
            return object;
        }
    }

    return null;
}

fn contains(list: []const []const u8, wanted: []const u8) bool {
    std.debug.assert(wanted.len > 0);
    std.debug.assert(list.len <= shape_module.columns_max);

    for (list) |item| {
        if (std.mem.eql(u8, item, wanted)) {
            return true;
        }
    }

    return false;
}

fn optional_equal(left: ?[]const u8, right: ?[]const u8) bool {
    std.debug.assert(left == null or left.?.len <= std.math.maxInt(u32));

    if (left == null or right == null) {
        return left == null and right == null;
    }

    return std.mem.eql(u8, left.?, right.?);
}

const testing_db = @import("../../db.zig");

/// The differences between a database made by `expected_sql` and one made by `live_sql`.
fn differences_of(
    arena: std.mem.Allocator,
    comptime expected_sql: [*:0]const u8,
    comptime live_sql: [*:0]const u8,
) ![]const Difference {
    var runtime = try testing_db.Runtime.init(.{});
    defer runtime.deinit();
    var expected = try testing_db.open(&runtime, ":memory:");
    defer expected.close();
    var live = try testing_db.open(&runtime, ":memory:");
    defer live.close();

    try expected.exec(expected_sql);
    try live.exec(live_sql);

    const expected_shape = try shape_module.read(&expected, arena);
    const live_shape = try shape_module.read(&live, arena);

    return compare(arena, expected_shape, live_shape);
}

test "a column the database holds stricter than this release is not compatible" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    // The dashboard on 2026-10-06: the code stopped writing `role`, the column stayed NOT NULL.
    const found = try differences_of(
        arena_state.allocator(),
        "CREATE TABLE users (id TEXT PRIMARY KEY, role TEXT)",
        "CREATE TABLE users (id TEXT PRIMARY KEY, role TEXT NOT NULL)",
    );

    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("users.role", found[0].subject);
    try std.testing.expect(!found[0].compatible);
}

test "a column the database holds looser than this release is compatible" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const found = try differences_of(
        arena_state.allocator(),
        "CREATE TABLE users (id TEXT PRIMARY KEY, role TEXT NOT NULL)",
        "CREATE TABLE users (id TEXT PRIMARY KEY, role TEXT NOT NULL DEFAULT '')",
    );

    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expect(found[0].compatible);
    try std.testing.expectEqual(Difference.Change.differs, found[0].change);
}

test "what a newer release added is compatible only when this one may leave it out" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const found = try differences_of(
        arena_state.allocator(),
        "CREATE TABLE a (id TEXT PRIMARY KEY)",
        "CREATE TABLE a (id TEXT PRIMARY KEY, note TEXT, size INTEGER NOT NULL);" ++
            "CREATE TABLE later (id TEXT PRIMARY KEY); CREATE INDEX a_note ON a (note);" ++
            "CREATE UNIQUE INDEX a_size ON a (size)",
    );

    try std.testing.expectEqual(@as(usize, 5), found.len);

    for (found) |difference| {
        const strict = std.mem.eql(u8, difference.subject, "a.size") or
            std.mem.eql(u8, difference.subject, "index a_size");

        try std.testing.expectEqual(!strict, difference.compatible);
        try std.testing.expectEqual(Difference.Change.extra, difference.change);
    }
}

test "what this release needs and the database lacks is not compatible" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const found = try differences_of(
        arena_state.allocator(),
        "CREATE TABLE a (id TEXT PRIMARY KEY, note TEXT); CREATE TABLE b (id TEXT);" ++
            "CREATE INDEX a_note ON a (note)",
        "CREATE TABLE a (id TEXT PRIMARY KEY)",
    );

    try std.testing.expectEqual(@as(usize, 3), found.len);

    for (found) |difference| {
        try std.testing.expect(!difference.compatible);
        try std.testing.expectEqual(Difference.Change.missing, difference.change);
    }
}

test "a reference the database lacks is looser, one only it has is stricter" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const found = try differences_of(
        arena_state.allocator(),
        "CREATE TABLE p (id TEXT PRIMARY KEY); CREATE TABLE c (p TEXT REFERENCES p(id))",
        "CREATE TABLE p (id TEXT PRIMARY KEY, code TEXT UNIQUE); CREATE TABLE c (p TEXT)",
    );

    try std.testing.expectEqual(@as(usize, 3), found.len);
    try std.testing.expectEqualStrings("p -> p(id) on delete NO ACTION", found[0].expected);
    try std.testing.expect(found[0].compatible);
    try std.testing.expect(found[1].compatible);
    try std.testing.expectEqualStrings("unique(code)", found[2].live);
    try std.testing.expect(!found[2].compatible);
}
