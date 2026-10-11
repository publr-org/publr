const std = @import("std");
const db = @import("../lib/db.zig");
const auth = @import("../lib/auth.zig");
const report = @import("../lib/report.zig");
const settings = @import("../store/settings.zig");
const activity = @import("../store/activity.zig");
const registry = @import("registry.zig");
const builtin = @import("builtin");

pub const backup = @import("gate/backup.zig");
pub const probes = @import("gate/probes.zig");

/// The setting that names the release that last opened the database.
pub const release_key = "publr.release";

pub const Options = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    runtime: *db.Runtime,
    db_path: []const u8,
    /// This binary's release.
    release: []const u8,
    now_ms: i64,
    auth: *auth.State,
    /// Back the whole site up before an update; off where there are no files (the browser).
    backup: bool = true,
    /// The folder around the site (`publr.zon`, apps); the one `publr` runs in when null.
    project_dir: ?[]const u8 = null,
};

pub const Outcome = enum {
    /// Made now from `schema.sql`.
    fresh,
    /// Opened by this release before: shape checked, nothing changed.
    unchanged,
    /// Another release opened it last, or migrations ran: backed up, brought up to date.
    updated,
    /// Made before releases recorded themselves (0.3.0): rebuilt to this release's shape.
    adopted,
};

pub const Error = error{DatabaseRefused};

/// Every open of a site's database goes through here before anything else reads it: a new
/// database is made; an older one is backed up and migrated; one a newer release migrated
/// is opened only when this release can still run on it; and a database whose shape is not
/// what its migrations say is refused, saying why, before a visitor meets it.
pub fn open(connection: *db.Db, options: Options) !Outcome {
    std.debug.assert(options.release.len > 0);
    std.debug.assert(connection.transaction_depth == 0);

    var arena_state = std.heap.ArenaAllocator.init(options.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (!try db.schema.has_table(connection, "settings")) {
        try make_fresh(connection, options);
        return .fresh;
    }

    const before = try settings.get(connection, arena, release_key);
    const recorded = if (try db.schema.has_table(connection, "migrations"))
        try db.migration.applied(connection, arena)
    else
        &.{};
    const plan = try db.migration.plan_of(arena, registry.SDK.migrations, recorded);

    if (plan.unknown.len > 0 and !plan.newer_compatible()) {
        refuse_newer(before orelse "an unknown release", options.release, plan.unknown);
        return error.DatabaseRefused;
    }

    var expected = try expected_database(options.runtime);
    defer expected.close();

    const same_release = before != null and std.mem.eql(u8, before.?, options.release);
    const missing = try lacks_schema(connection, &expected, arena);
    const updating = !same_release or plan.changes() or missing;

    if (!updating) {
        return .unchanged;
    }

    if (options.backup) {
        try back_up(connection, arena, options, before orelse "");
    }

    try update(connection, &expected, arena, options, .{
        .plan = plan,
        .adopt = before == null,
        .record_release = !same_release,
        .before = before orelse "",
    });

    return if (before == null) .adopted else .updated;
}

fn back_up(
    connection: *db.Db,
    arena: std.mem.Allocator,
    options: Options,
    before: []const u8,
) !void {
    std.debug.assert(connection.transaction_depth == 0);
    std.debug.assert(options.backup);

    const site = try backup.Site.of(options.io, arena, options.db_path, options.project_dir);
    const made = try backup.make(site, connection, arena, .{
        .from = before,
        .to = options.release,
        .at_ms = options.now_ms,
        .database = site.database,
    }, .{});

    report.info("publr: backed the site up to {s} before opening it with {s}\n", .{
        made,
        options.release,
    });
}

/// Whether the database lacks something this release's schema has and would make: a table,
/// an index. What only a migration can change (a column, a rule) is the shape check's.
fn lacks_schema(connection: *db.Db, expected: *db.Db, arena: std.mem.Allocator) !bool {
    std.debug.assert(connection.transaction_depth == 0);
    std.debug.assert(connection != expected);

    const differences = try db.shape.compare(
        arena,
        try db.shape.read(expected, arena),
        try db.shape.read(connection, arena),
    );

    for (differences) |difference| {
        if (!difference.compatible) {
            return true;
        }
    }

    return false;
}

const Steps = struct {
    plan: db.migration.Plan,
    /// Rebuild tables that drifted from `schema.sql`: only for a database from before 0.3.0.
    adopt: bool,
    record_release: bool,
    /// The release that opened it last; empty before releases recorded themselves.
    before: []const u8,
};

fn update(
    connection: *db.Db,
    expected: *db.Db,
    arena: std.mem.Allocator,
    options: Options,
    steps: Steps,
) !void {
    std.debug.assert(connection.transaction_depth == 0);
    std.debug.assert(options.now_ms > 0);

    // A table rebuild drops and renames: references are checked once, before commit.
    try connection.exec("PRAGMA foreign_keys = OFF");
    defer connection.exec("PRAGMA foreign_keys = ON") catch |err| {
        std.log.err("turning foreign keys back on: {t}", .{err});
    };

    var transaction = try connection.transaction();
    defer transaction.rollback();

    try db.migration.run(connection, steps.plan, options.now_ms);
    try apply_schema(connection);

    if (steps.adopt) {
        try adopt(connection, expected, arena);
    }

    try check_shape(connection, expected, arena);
    try check_integrity(connection, arena);
    try check_probes(connection, arena, options);

    if (steps.record_release) {
        try settings.set(connection, release_key, options.release, options.now_ms);
        try record_update(connection, arena, options, steps.before);
    }

    try transaction.commit();
}

/// `publr.updated` in the activity log, from the system: what Deployments shows as the line
/// between deployments made under one release and the next.
fn record_update(
    connection: *db.Db,
    arena: std.mem.Allocator,
    options: Options,
    before: []const u8,
) !void {
    std.debug.assert(connection.transaction_depth >= 1);
    std.debug.assert(options.release.len > 0);

    const input = try std.json.Stringify.valueAlloc(arena, .{
        .from = before,
        .to = options.release,
    }, .{});

    try activity.append(connection, .{
        .id = 0,
        .at = options.now_ms,
        .actor = "system",
        .app = "",
        .operation = "publr.updated",
        .input = input,
        .units = "[]",
        .calls = "[]",
    });
}

fn make_fresh(connection: *db.Db, options: Options) !void {
    std.debug.assert(connection.transaction_depth == 0);
    std.debug.assert(options.now_ms > 0);

    var transaction = try connection.transaction();
    defer transaction.rollback();

    try apply_schema(connection);
    try db.migration.record_all(connection, registry.SDK.migrations, options.now_ms);
    try settings.set(connection, release_key, options.release, options.now_ms);
    try transaction.commit();
}

/// `schema.sql` and every compiled-in plugin's tables: creates what is missing, leaves
/// what is there.
fn apply_schema(connection: *db.Db) !void {
    std.debug.assert(connection.transaction_depth <= 1);
    std.debug.assert(db.schema.sql.len > 0);

    try db.schema.apply(connection);
    try registry.SDK.apply_schemas(connection);
}

/// What opening the database would find, without changing it: for `publr db check`.
pub const Status = struct {
    /// The release that last opened it; null before releases recorded themselves.
    release: ?[]const u8,
    plan: db.migration.Plan,
    differences: []const db.shape.Difference,

    pub fn refused(found: Status) bool {
        std.debug.assert(found.differences.len <= db.shape.tables_max * db.shape.columns_max);

        for (found.differences) |difference| {
            if (!difference.compatible) {
                return true;
            }
        }

        return found.plan.unknown.len > 0 and !found.plan.newer_compatible();
    }
};

pub fn status(connection: *db.Db, runtime: *db.Runtime, arena: std.mem.Allocator) !Status {
    std.debug.assert(connection.transaction_depth == 0);
    std.debug.assert(runtime.open_count >= 1);

    var expected = try expected_database(runtime);
    defer expected.close();

    const versioned = try db.schema.has_table(connection, "migrations");
    const recorded = if (versioned) try db.migration.applied(connection, arena) else &.{};
    const has_settings = try db.schema.has_table(connection, "settings");

    return .{
        .release = if (has_settings) try settings.get(connection, arena, release_key) else null,
        .plan = try db.migration.plan_of(arena, registry.SDK.migrations, recorded),
        .differences = try db.shape.compare(
            arena,
            try db.shape.read(&expected, arena),
            try db.shape.read(connection, arena),
        ),
    };
}

/// The shape this release expects: its schema, made in memory.
fn expected_database(runtime: *db.Runtime) !db.Db {
    std.debug.assert(runtime.open_count >= 1);

    var expected = try db.open(runtime, ":memory:");
    errdefer expected.close();

    try apply_schema(&expected);

    return expected;
}

fn adopt(connection: *db.Db, expected: *db.Db, arena: std.mem.Allocator) !void {
    std.debug.assert(connection.transaction_depth == 1);
    std.debug.assert(connection != expected);

    const differences = try db.shape.compare(
        arena,
        try db.shape.read(expected, arena),
        try db.shape.read(connection, arena),
    );
    var rebuilt: std.ArrayList([]const u8) = .empty;

    for (differences) |difference| {
        if (difference.compatible) {
            continue;
        }

        const end = std.mem.indexOfAny(u8, difference.subject, ". ") orelse
            difference.subject.len;
        const table = difference.subject[0..end];
        const plain = try db.schema.has_table(connection, table);

        if (!plain or contains(rebuilt.items, table)) {
            continue;
        }

        db.rebuild.rebuild(connection, expected, arena, table) catch |err| {
            refusal("publr: could not bring table {s} to this release's shape: {t}: {s}", .{
                table,
                err,
                connection.message(),
            });
            return error.DatabaseRefused;
        };
        try rebuilt.append(arena, table);
        report.info("publr: rebuilt table {s} to this release's shape, its rows kept\n", .{
            table,
        });
    }
}

fn check_shape(connection: *db.Db, expected: *db.Db, arena: std.mem.Allocator) !void {
    std.debug.assert(connection.transaction_depth >= 1);
    std.debug.assert(connection != expected);

    const differences = try db.shape.compare(
        arena,
        try db.shape.read(expected, arena),
        try db.shape.read(connection, arena),
    );
    var refused: u32 = 0;

    for (differences) |difference| {
        if (!difference.compatible) {
            refused += 1;
            refusal("  {s}: this release expects {s}, the database has {s}", .{
                difference.subject,
                difference.expected,
                difference.live,
            });
        }
    }

    if (refused > 0) {
        refusal("publr: the database's shape is not what its migrations say ({d} " ++
            "difference(s) above). A migration is missing, or it was changed by hand; " ++
            "nothing was changed. `publr db check` lists them again.", .{refused});
        return error.DatabaseRefused;
    }
}

fn check_integrity(connection: *db.Db, arena: std.mem.Allocator) !void {
    std.debug.assert(connection.transaction_depth >= 1);

    const Row = struct {
        table: []const u8,
        rowid: ?i64,
        parent: []const u8,
    };
    var references = try connection.prepare("PRAGMA foreign_key_check");
    defer references.finalize();

    if (try references.step()) {
        const row = try references.read(Row, arena);

        refusal("publr: a row of {s} refers to a missing {s}; nothing was changed", .{
            row.table,
            row.parent,
        });
        return error.DatabaseRefused;
    }

    var quick = try connection.prepare("PRAGMA quick_check");
    defer quick.finalize();

    const Verdict = struct {
        text: []const u8,
    };

    if (try quick.step()) {
        const verdict = try quick.read(Verdict, arena);

        if (!std.mem.eql(u8, verdict.text, "ok")) {
            refusal("publr: the database is damaged: {s}", .{verdict.text});
            return error.DatabaseRefused;
        }
    }
}

fn check_probes(connection: *db.Db, arena: std.mem.Allocator, options: Options) !void {
    std.debug.assert(connection.transaction_depth >= 1);
    std.debug.assert(options.now_ms > 0);

    const failed = try probes.run(connection, options.io, arena, options.auth, options.now_ms);

    if (failed) |failure| {
        refusal("publr: the database refused a {s}: {s}; nothing was changed", .{
            failure.what,
            failure.message,
        });
        return error.DatabaseRefused;
    }
}

fn refuse_newer(
    before: []const u8,
    release: []const u8,
    unknown: []const db.migration.Applied,
) void {
    std.debug.assert(release.len > 0);
    std.debug.assert(unknown.len > 0);

    for (unknown) |row| {
        refusal("  migration {s} {s}{s}", .{
            row.source,
            row.name,
            if (row.one_way) " (one-way)" else "",
        });
    }

    refusal("publr: this database was updated by Publr {s}; this is {s}, which cannot " ++
        "run on it. Update Publr, or restore the backup taken before that update " ++
        "(`publr backups`, `publr restore <name>`).", .{ before, release });
}

/// Why the gate refuses, for whoever started Publr; the tests that provoke one check the
/// error instead.
fn refusal(comptime format: []const u8, args: anytype) void {
    if (builtin.is_test) {
        return;
    }

    report.err(format, args);
}

fn contains(list: []const []const u8, wanted: []const u8) bool {
    std.debug.assert(wanted.len > 0);

    for (list) |item| {
        if (std.mem.eql(u8, item, wanted)) {
            return true;
        }
    }

    return false;
}

test {
    _ = @import("gate/gate_test.zig");
}
