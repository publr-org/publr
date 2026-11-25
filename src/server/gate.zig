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
pub const conform = @import("gate/conform.zig");
pub const Status = @import("gate/status.zig").Status;
pub const status = @import("gate/status.zig").status;

/// The setting that names the release that last opened the database.
pub const release_key = "publr.release";

pub const Options = struct {
    /// Back the whole site up before an update; off where there are no files (the browser).
    backup: bool = true,
    /// The folder around the site (`publr.zon`, apps); the one `publr` runs in when null.
    project_dir: ?[]const u8 = null,
};

/// One open of a site's database: what it reads, and how the caller asked for it.
const Opening = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    runtime: *db.Runtime,
    db_path: []const u8,
    /// This binary's release.
    release: []const u8,
    now_ms: i64,
    auth: *auth.State,
    backup: bool,
    project_dir: ?[]const u8,
};

pub const Outcome = enum {
    /// Made now from `schema.sql`.
    fresh,
    /// Opened by this release before: shape checked, nothing changed.
    unchanged,
    /// Another release opened it last, or migrations ran: backed up, brought up to date.
    updated,
};

pub const Error = error{DatabaseRefused};

/// Every open of a site's database goes through here before anything else reads it: a new
/// database is made; an older one is backed up and migrated; one a newer release migrated
/// is opened only when this release can still run on it; and a database whose shape is not
/// what its migrations say is refused, saying why, before a visitor meets it.
pub fn open(
    connection: *db.Db,
    io: std.Io,
    gpa: std.mem.Allocator,
    runtime: *db.Runtime,
    auth_state: *auth.State,
    db_path: []const u8,
    release: []const u8,
    now_ms: i64,
    options: Options,
) !Outcome {
    std.debug.assert(release.len > 0);
    std.debug.assert(connection.transaction_depth == 0);

    return pass(connection, .{
        .io = io,
        .gpa = gpa,
        .runtime = runtime,
        .db_path = db_path,
        .release = release,
        .now_ms = now_ms,
        .auth = auth_state,
        .backup = options.backup,
        .project_dir = options.project_dir,
    });
}

fn pass(connection: *db.Db, opening: Opening) !Outcome {
    std.debug.assert(opening.release.len > 0);
    std.debug.assert(connection.transaction_depth == 0);

    var arena_state = std.heap.ArenaAllocator.init(opening.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (!try db.schema.has_table(connection, "settings")) {
        try make_fresh(connection, opening);
        return .fresh;
    }

    const before = try settings.get(connection, arena, release_key);
    const recorded = try recorded_migrations(connection, arena);
    const plan = try db.migration.plan_of(arena, registry.SDK.migrations, recorded);

    if (plan.unknown.len > 0 and !plan.newer_compatible()) {
        refuse_newer(before orelse "an unknown release", opening.release, plan.unknown);
        return error.DatabaseRefused;
    }

    var expected = try expected_database(opening.runtime);
    defer expected.close();

    const same_release = before != null and std.mem.eql(u8, before.?, opening.release);
    const missing = try lacks_schema(connection, &expected, arena);
    const updating = !same_release or plan.changes() or missing;

    if (!updating) {
        return .unchanged;
    }

    if (opening.backup) {
        try back_up(connection, arena, opening, before orelse "");
    }

    try update(connection, &expected, arena, opening, .{
        .plan = plan,
        .record_release = !same_release,
        .before = before orelse "",
    });

    return .updated;
}

/// The migrations the database records that this release's chain reads: none before the
/// table exists, and none of core's from before its baseline.
pub fn recorded_migrations(
    connection: *db.Db,
    arena: std.mem.Allocator,
) ![]const db.migration.Applied {
    std.debug.assert(connection.transaction_depth <= 1);
    std.debug.assert(db.migrations.baseline.len > 0);

    if (!try db.schema.has_table(connection, "migrations")) {
        return &.{};
    }

    return db.migrations.since_baseline(arena, try db.migration.applied(connection, arena));
}

fn back_up(
    connection: *db.Db,
    arena: std.mem.Allocator,
    opening: Opening,
    before: []const u8,
) !void {
    std.debug.assert(connection.transaction_depth == 0);
    std.debug.assert(opening.backup);

    const site = try backup.Site.of(opening.io, arena, opening.db_path, opening.project_dir);
    const made = try backup.make(site, connection, arena, .{
        .from = before,
        .to = opening.release,
        .at_ms = opening.now_ms,
        .database = site.database,
    }, .{});

    report.info("publr: backed the site up to {s} before opening it with {s}\n", .{
        made,
        opening.release,
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
    record_release: bool,
    /// The release that opened it last; empty when none is recorded.
    before: []const u8,
};

fn update(
    connection: *db.Db,
    expected: *db.Db,
    arena: std.mem.Allocator,
    opening: Opening,
    steps: Steps,
) !void {
    std.debug.assert(connection.transaction_depth == 0);
    std.debug.assert(opening.now_ms > 0);

    // A migration may rebuild a table (drop, rename): references are checked once, before
    // commit.
    try connection.exec("PRAGMA foreign_keys = OFF");
    defer connection.exec("PRAGMA foreign_keys = ON") catch |err| {
        std.log.err("turning foreign keys back on: {t}", .{err});
    };

    var transaction = try connection.transaction();
    defer transaction.rollback();

    try db.migration.run(connection, steps.plan, opening.now_ms);
    try apply_schema(connection);
    try check_shape(connection, expected, arena);
    try check_integrity(connection, arena);
    try check_probes(connection, arena, opening);

    if (steps.record_release) {
        try settings.set(connection, release_key, opening.release, opening.now_ms);
        try record_update(connection, arena, .{
            .from = steps.before,
            .to = opening.release,
            .at_ms = opening.now_ms,
        });
    }

    try transaction.commit();
}

/// One release taking over a database from another.
pub const Update = struct {
    /// The release that opened it last; empty when none is recorded.
    from: []const u8,
    to: []const u8,
    at_ms: i64,
};

/// `publr.updated` in the activity log, from the system: what Deployments shows as the line
/// between deployments made under one release and the next.
pub fn record_update(connection: *db.Db, arena: std.mem.Allocator, moved: Update) !void {
    std.debug.assert(connection.transaction_depth >= 1);
    std.debug.assert(moved.to.len > 0);

    const input = try std.json.Stringify.valueAlloc(arena, .{
        .from = moved.from,
        .to = moved.to,
    }, .{});

    try activity.append(connection, .{
        .id = 0,
        .at = moved.at_ms,
        .actor = "system",
        .app = "",
        .operation = "publr.updated",
        .input = input,
        .units = "[]",
        .calls = "[]",
    });
}

fn make_fresh(connection: *db.Db, opening: Opening) !void {
    std.debug.assert(connection.transaction_depth == 0);
    std.debug.assert(opening.now_ms > 0);

    var transaction = try connection.transaction();
    defer transaction.rollback();

    try apply_schema(connection);
    try db.migration.record_all(connection, registry.SDK.migrations, opening.now_ms);
    try settings.set(connection, release_key, opening.release, opening.now_ms);
    try transaction.commit();
}

/// `schema.sql` and every compiled-in plugin's tables: creates what is missing, leaves
/// what is there.
pub fn apply_schema(connection: *db.Db) !void {
    std.debug.assert(connection.transaction_depth <= 1);
    std.debug.assert(db.schema.sql.len > 0);

    try db.schema.apply(connection);
    try registry.SDK.apply_schemas(connection);
}

/// The shape this release expects: its schema, made in memory.
pub fn expected_database(runtime: *db.Runtime) !db.Db {
    std.debug.assert(runtime.open_count >= 1);

    var expected = try db.open(runtime, ":memory:");
    errdefer expected.close();

    try apply_schema(&expected);

    return expected;
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

pub fn check_integrity(connection: *db.Db, arena: std.mem.Allocator) !void {
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

fn check_probes(connection: *db.Db, arena: std.mem.Allocator, opening: Opening) !void {
    std.debug.assert(connection.transaction_depth >= 1);
    std.debug.assert(opening.now_ms > 0);

    const failed = try probes.run(connection, opening.io, arena, opening.auth, opening.now_ms);

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
pub fn refusal(comptime format: []const u8, args: anytype) void {
    if (builtin.is_test) {
        return;
    }

    report.err(format, args);
}

test {
    _ = @import("gate/gate_test.zig");
    _ = @import("gate/conform.zig");
}
