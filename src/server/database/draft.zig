const std = @import("std");
const db = @import("../../lib/db.zig");

/// The start of the next migration: what this build's schema adds to `released` (the
/// schema the last release shipped), written as a migration file. Added tables, columns
/// and indexes are written out, each checked first so it may run again; anything changed
/// or removed is left as a note, since only a person knows what the data needs.
pub fn write(
    runtime: *db.Runtime,
    arena: std.mem.Allocator,
    released: [:0]const u8,
    out: *std.Io.Writer,
) !void {
    std.debug.assert(released.len > 0);
    std.debug.assert(std.mem.indexOf(u8, released, "CREATE") != null);

    var before = try db.open(runtime, ":memory:");
    defer before.close();
    // Core's schema only: a compiled-in plugin drafts its own migrations.
    var after = try db.open(runtime, ":memory:");
    defer after.close();

    try db.schema.apply(&after);

    try exec_text(&before, arena, released);

    const differences = try db.shape.compare(
        arena,
        try db.shape.read(&after, arena),
        try db.shape.read(&before, arena),
    );
    const one_way = has_removal(differences);

    try out.print(
        \\const std = @import("std");
        \\const db = @import("../../db.zig");
        \\
        \\/// Drafted by `zig build migration-draft`; read it, finish it, keep it small. It says
        \\/// everything itself: never `schema.sql`, never today's code.
        \\pub const one_way = {};
        \\
        \\pub fn up(connection: *db.Db) db.Error!void {{
        \\    std.debug.assert(connection.transaction_depth >= 1);
        \\
    , .{one_way});

    for (differences) |difference| {
        try write_step(&after, arena, out, difference);
    }

    try out.print("}}\n", .{});
}

fn write_step(
    after: *db.Db,
    arena: std.mem.Allocator,
    out: *std.Io.Writer,
    difference: db.shape.Difference,
) !void {
    std.debug.assert(difference.subject.len > 0);

    // Compared from the old schema's side: "missing" there is what this build adds.
    if (difference.change != .missing) {
        try out.print("    // TODO {s}: was {s}, is now {s}. Removing or changing is one-way: " ++
            "move the data, then drop.\n", .{
            difference.subject,
            difference.live,
            difference.expected,
        });
        return;
    }

    const dot = std.mem.indexOfScalar(u8, difference.subject, '.');

    if (std.mem.startsWith(u8, difference.subject, "index ")) {
        const sql = try statement_of(after, arena, difference.subject["index ".len..]);

        try out.print("    try connection.exec(\n        \\\\{s}\n    );\n", .{
            try if_not_exists(arena, sql, "CREATE INDEX ", "CREATE UNIQUE INDEX "),
        });
    } else if (dot) |at| {
        const table = difference.subject[0..at];
        const column = difference.subject[at + 1 ..];

        try out.print(
            \\    if (!try db.schema.has_column(connection, "{s}", "{s}")) {{
            \\        try connection.exec("ALTER TABLE {s} ADD COLUMN {s} {s}");
            \\    }}
            \\
        , .{ table, column, table, column, difference.expected });
    } else if (std.mem.eql(u8, difference.expected, "a table")) {
        const sql = try statement_of(after, arena, difference.subject);

        try out.print("    try connection.exec(\n        \\\\{s}\n    );\n", .{
            try if_not_exists(arena, sql, "CREATE TABLE ", "CREATE VIRTUAL TABLE "),
        });
    } else {
        try out.print("    // TODO {s}: {s}\n", .{ difference.subject, difference.expected });
    }
}

fn has_removal(differences: []const db.shape.Difference) bool {
    std.debug.assert(differences.len <= db.shape.objects_max * db.shape.columns_max);

    for (differences) |difference| {
        if (difference.change != .missing) {
            return true;
        }
    }

    return false;
}

fn statement_of(connection: *db.Db, arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    std.debug.assert(name.len > 0);

    var select = try connection.prepare("SELECT sql FROM sqlite_schema WHERE name = ?1");
    defer select.finalize();

    try select.bind_text(1, name);

    if (!try select.step()) {
        return error.Missing;
    }

    const Row = struct {
        sql: []const u8,
    };

    return try db.shape.normalize(arena, (try select.read(Row, arena)).sql);
}

/// `CREATE TABLE x` as `CREATE TABLE IF NOT EXISTS x`, so the step may run again.
fn if_not_exists(
    arena: std.mem.Allocator,
    sql: []const u8,
    plain: []const u8,
    other: []const u8,
) ![]const u8 {
    std.debug.assert(sql.len > 0);
    std.debug.assert(plain.len > 0);

    for ([_][]const u8{ other, plain }) |prefix| {
        if (std.mem.startsWith(u8, sql, prefix)) {
            const rest = sql[prefix.len..];

            return std.fmt.allocPrint(arena, "{s}IF NOT EXISTS {s}", .{ prefix, rest });
        }
    }

    return sql;
}

/// `released`, a whole schema file, run statement by statement.
fn exec_text(connection: *db.Db, arena: std.mem.Allocator, released: [:0]const u8) !void {
    std.debug.assert(released.len > 0);
    std.debug.assert(connection.transaction_depth == 0);

    var statements = std.mem.splitSequence(u8, released, ";\n");

    while (statements.next()) |raw| {
        const statement = std.mem.trim(u8, raw, " \n\t");

        if (statement.len == 0) {
            continue;
        }

        // The released schema's own text, never data.
        var prepared = try connection.prepare_dynamic(try arena.dupe(u8, statement));
        defer prepared.finalize();

        try prepared.exec();
    }
}
