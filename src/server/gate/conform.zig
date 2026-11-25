const std = @import("std");
const db = @import("../../lib/db.zig");
const settings = @import("../../store/settings.zig");
const registry = @import("../registry.zig");
const gate = @import("../gate.zig");
const rebuild = @import("conform/rebuild.zig");

pub const Change = rebuild.Change;
pub const LeftOut = rebuild.LeftOut;
pub const left_out_name = "left-out.json";

/// Who conforms the database, and when.
pub const Conforming = struct {
    io: std.Io,
    runtime: *db.Runtime,
    /// This binary's release: the shape the database is brought to.
    release: []const u8,
    now_ms: i64,
};

pub const Options = struct {
    /// Do all of it in a transaction, then roll it back.
    dry_run: bool = false,
    /// Where what is left out is written before the commit; needed when anything is.
    left_out_path: ?[]const u8 = null,
};

pub const Outcome = struct {
    /// Why it was not conformed, nothing changed; null when it was, or could be.
    refusal: ?[]const u8 = null,
    changes: []const Change = &.{},
    left_out: []const LeftOut = &.{},
    /// Every row and value left out: `{"release", "rows", "values"}`.
    left_out_json: []const u8 = "",

    pub fn nothing(outcome: Outcome) bool {
        std.debug.assert(outcome.changes.len <= db.shape.tables_max * db.shape.columns_max);
        std.debug.assert(outcome.refusal == null or outcome.refusal.?.len > 0);

        return outcome.refusal == null and outcome.changes.len == 0 and
            outcome.left_out.len == 0;
    }
};

/// A database this release refuses only for its shape, brought to the shape this release
/// makes: what the gate does on opening it (migrations, missing tables), then each table
/// whose differences it refuses rebuilt, refused extra indexes and triggers dropped, rows
/// and values with no place left out, and the migrations recorded as a new database's are.
/// One transaction; `db check` must then say this release opens it, or none of it lands.
pub fn run(
    connection: *db.Db,
    arena: std.mem.Allocator,
    conforming: Conforming,
    options: Options,
) !Outcome {
    std.debug.assert(connection.transaction_depth == 0);
    std.debug.assert(conforming.now_ms > 0);

    if (try refusal_of(connection, arena)) |why| {
        return .{
            .refusal = why,
        };
    }

    const recorded = try gate.recorded_migrations(connection, arena);
    const plan = try db.migration.plan_of(arena, registry.SDK.migrations, recorded);
    var expected = try gate.expected_database(conforming.runtime);
    defer expected.close();

    // A rebuild drops and renames tables: references are checked once, before commit, and
    // nothing else in the schema is rewritten for the rename.
    try connection.exec("PRAGMA foreign_keys = OFF");
    defer connection.exec("PRAGMA foreign_keys = ON") catch |err| {
        std.log.err("turning foreign keys back on: {t}", .{err});
    };
    try connection.exec("PRAGMA legacy_alter_table = ON");
    defer connection.exec("PRAGMA legacy_alter_table = OFF") catch |err| {
        std.log.err("turning legacy ALTER TABLE back off: {t}", .{err});
    };

    var transaction = try connection.transaction();
    defer transaction.rollback();

    try db.migration.run(connection, plan, conforming.now_ms);
    try gate.apply_schema(connection);

    var work: rebuild.Work = .{
        .connection = connection,
        .expected = &expected,
        .arena = arena,
    };

    if (try repair(&work)) |why| {
        return .{
            .refusal = why,
        };
    }

    try forget_unreleased(&work, plan);

    if (work.changes.items.len == 0 and work.left_out.items.len == 0) {
        return .{};
    }

    try @import("conform/left_out.zig").references(&work);
    try record(connection, arena, conforming, plan);
    try check(connection, &expected, arena);

    const outcome: Outcome = .{
        .changes = work.changes.items,
        .left_out = work.left_out.items,
        .left_out_json = try left_out_json(&work, conforming.release),
    };

    if (options.dry_run) {
        return outcome;
    }

    if (outcome.left_out.len > 0) {
        const path = options.left_out_path orelse return error.NoLeftOutPath;

        try std.Io.Dir.cwd().writeFile(conforming.io, .{
            .sub_path = path,
            .data = outcome.left_out_json,
        });
    }

    try transaction.commit();

    return outcome;
}

/// Why the database is not one to conform: damaged, not a site's, or a newer release's.
fn refusal_of(connection: *db.Db, arena: std.mem.Allocator) !?[]const u8 {
    std.debug.assert(connection.transaction_depth == 0);
    std.debug.assert(registry.SDK.migrations.len <= db.migration.migrations_max);

    if (!try db.schema.has_table(connection, "settings")) {
        return "it has no settings table: it is not a Publr site's database";
    }

    const Verdict = struct {
        text: []const u8,
    };
    var quick = try connection.prepare("PRAGMA quick_check");
    defer quick.finalize();

    if (try quick.step()) {
        const verdict = try quick.read(Verdict, arena);

        if (!std.mem.eql(u8, verdict.text, "ok")) {
            return try std.fmt.allocPrint(arena, "the database is damaged: {s}", .{verdict.text});
        }
    }

    var references = try connection.prepare("SELECT \"table\" FROM pragma_foreign_key_check");
    defer references.finalize();

    if (try references.step()) {
        const row = try references.read(Verdict, arena);

        return try std.fmt.allocPrint(arena, "a row of {s} refers to a missing one", .{row.text});
    }

    return newer_of(connection, arena);
}

/// A database a newer release migrated is that release's to open, unless this one may run
/// on it. What a development build recorded as `unreleased` is no release's.
fn newer_of(connection: *db.Db, arena: std.mem.Allocator) !?[]const u8 {
    std.debug.assert(connection.transaction_depth == 0);

    const recorded = try gate.recorded_migrations(connection, arena);
    const plan = try db.migration.plan_of(arena, registry.SDK.migrations, recorded);
    var released: std.ArrayList(db.migration.Applied) = .empty;
    var names: std.ArrayList(u8) = .empty;

    for (plan.unknown) |row| {
        if (!std.mem.eql(u8, row.name, db.migration.unreleased)) {
            try released.append(arena, row);
            try names.print(arena, " {s} {s}", .{ row.source, row.name });
        }
    }

    const newer: db.migration.Plan = .{
        .pending = &.{},
        .unknown = released.items,
        .superseded = &.{},
    };

    if (released.items.len == 0 or newer.newer_compatible()) {
        return null;
    }

    std.debug.assert(names.items.len > 0);

    return try std.fmt.allocPrint(arena, "a newer release migrated it:{s}", .{names.items});
}

/// Every table whose differences this release refuses rebuilt; every refused index or
/// trigger on another table dropped or made again.
fn repair(work: *rebuild.Work) !?[]const u8 {
    std.debug.assert(work.connection.transaction_depth >= 1);
    std.debug.assert(work.changes.items.len == 0);

    const arena = work.arena;
    const expected = try db.shape.read(work.expected, arena);
    const live = try db.shape.read(work.connection, arena);
    const differences = try db.shape.compare(arena, expected, live);
    var tables: std.ArrayList([]const u8) = .empty;
    var reasons: std.ArrayList(std.ArrayList(u8)) = .empty;

    for (differences) |difference| {
        if (difference.compatible or object_kind(difference.subject) != null) {
            continue;
        }

        const dot = std.mem.indexOfScalar(u8, difference.subject, '.');
        const name = difference.subject[0 .. dot orelse difference.subject.len];
        const wanted = expected.table(name) orelse continue;
        const found = live.table(name) orelse return error.Sqlite;

        if (wanted.virtual_sql != null or found.virtual_sql != null) {
            return try std.fmt.allocPrint(arena, "{s} is a full-text table this release " ++
                "makes differently; it cannot be rebuilt", .{name});
        }

        const added: u32 = @intCast(tables.items.len);
        const index = index_of(tables.items, name) orelse added;

        if (index == added) {
            try tables.append(arena, name);
            try reasons.append(arena, .empty);
        }

        try reasons.items[index].print(arena, "{s}{s}: expects {s}, has {s}", .{
            if (reasons.items[index].items.len == 0) "" else "; ",
            difference.subject,
            difference.expected,
            difference.live,
        });
    }

    for (tables.items, reasons.items) |name, reason| {
        try work.changes.append(arena, .{
            .kind = .rebuild,
            .name = name,
            .why = reason.items,
        });
        try rebuild.table(work, expected.table(name).?, live.table(name).?, live.objects);
    }

    try @import("conform/objects.zig").repair(work, differences, expected, live, tables.items);

    return null;
}

/// The `unreleased` migrations a development build recorded, when the gate refuses the
/// database for them: no release knows what they did.
fn forget_unreleased(work: *rebuild.Work, plan: db.migration.Plan) !void {
    std.debug.assert(work.connection.transaction_depth >= 1);
    std.debug.assert(plan.unknown.len <= db.migration.migrations_max);

    if (plan.unknown.len == 0 or plan.newer_compatible()) {
        return;
    }

    for (plan.unknown) |row| {
        if (std.mem.eql(u8, row.name, db.migration.unreleased)) {
            try work.changes.append(work.arena, .{
                .kind = .forget,
                .name = try std.fmt.allocPrint(work.arena, "{s} {s}", .{ row.source, row.name }),
            });
        }
    }
}

/// `index` or `trigger` for a difference about one; null for a table's or column's.
pub fn object_kind(subject: []const u8) ?db.shape.Object.Kind {
    std.debug.assert(subject.len > 0);

    if (std.mem.startsWith(u8, subject, "index ")) {
        return .index;
    }

    if (std.mem.startsWith(u8, subject, "trigger ")) {
        return .trigger;
    }

    return null;
}

pub fn index_of(names: []const []const u8, name: []const u8) ?u32 {
    std.debug.assert(name.len > 0);
    std.debug.assert(names.len <= db.shape.objects_max);

    for (names, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, name)) {
            return @intCast(index);
        }
    }

    return null;
}

/// The migrations a database in this release's shape records: `unreleased` rows no release
/// knows forgotten, every one of this release's recorded; and the release.
fn record(
    connection: *db.Db,
    arena: std.mem.Allocator,
    conforming: Conforming,
    plan: db.migration.Plan,
) !void {
    std.debug.assert(connection.transaction_depth >= 1);
    std.debug.assert(conforming.release.len > 0);

    for (plan.unknown) |row| {
        if (std.mem.eql(u8, row.name, db.migration.unreleased)) {
            var forget = try connection.prepare(
                "DELETE FROM migrations WHERE source = ?1 AND name = ?2",
            );
            defer forget.finalize();

            try forget.bind_text(1, row.source);
            try forget.bind_text(2, row.name);
            try forget.exec();
        }
    }

    try db.migration.record_all(connection, registry.SDK.migrations, conforming.now_ms);

    const before = try settings.get(connection, arena, gate.release_key) orelse "";

    if (!std.mem.eql(u8, before, conforming.release)) {
        try settings.set(connection, gate.release_key, conforming.release, conforming.now_ms);
        try gate.record_update(connection, arena, .{
            .from = before,
            .to = conforming.release,
            .at_ms = conforming.now_ms,
        });
    }
}

/// What `db check` asks, on the conformed database: nothing refused, nothing to run.
fn check(connection: *db.Db, expected: *db.Db, arena: std.mem.Allocator) !void {
    std.debug.assert(connection.transaction_depth >= 1);
    std.debug.assert(connection != expected);

    const recorded = try gate.recorded_migrations(connection, arena);
    const found: gate.Status = .{
        .release = try settings.get(connection, arena, gate.release_key),
        .plan = try db.migration.plan_of(arena, registry.SDK.migrations, recorded),
        .differences = try db.shape.compare(
            arena,
            try db.shape.read(expected, arena),
            try db.shape.read(connection, arena),
        ),
    };

    try gate.check_integrity(connection, arena);

    if (found.refused() or found.plan.changes()) {
        for (found.differences) |difference| {
            if (!difference.compatible) {
                gate.refusal("  {s}: this release expects {s}, the database has {s}", .{
                    difference.subject,
                    difference.expected,
                    difference.live,
                });
            }
        }

        return error.DatabaseRefused;
    }
}

fn left_out_json(work: *rebuild.Work, release: []const u8) ![]const u8 {
    std.debug.assert(release.len > 0);
    std.debug.assert(work.rows.items.len + work.values.items.len >= work.left_out.items.len);

    const rows = try std.mem.join(work.arena, ",\n", work.rows.items);
    const values = try std.mem.join(work.arena, ",\n", work.values.items);

    const layout = "{{\"release\":{f},\n\"rows\":[{s}],\n\"values\":[{s}]}}\n";

    return std.fmt.allocPrint(work.arena, layout, .{
        std.json.fmt(release, .{}),
        rows,
        values,
    });
}

test {
    _ = @import("conform_test.zig");
}
