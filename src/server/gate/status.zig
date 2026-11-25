const std = @import("std");
const db = @import("../../lib/db.zig");
const settings = @import("../../store/settings.zig");
const registry = @import("../registry.zig");
const gate = @import("../gate.zig");

/// The moment a rehearsal records its migrations at: the copy is thrown away.
const rehearsal_ms: i64 = 1;

/// What opening the database would find, without changing it: for `publr db check`.
pub const Status = struct {
    /// The release that last opened it; null when none is recorded.
    release: ?[]const u8,
    plan: db.migration.Plan,
    /// How the database differs from this release's shape once what the gate does on opening
    /// it (the pending migrations, the missing tables made) is done.
    differences: []const db.shape.Difference,
    /// The error a pending migration failed with, run on a copy; null when they ran.
    failure: ?[]const u8 = null,

    pub fn refused(found: Status) bool {
        std.debug.assert(found.differences.len <= db.shape.tables_max * db.shape.columns_max);
        std.debug.assert(found.failure == null or found.failure.?.len > 0);

        if (found.failure != null) {
            return true;
        }

        for (found.differences) |difference| {
            if (!difference.compatible) {
                return true;
            }
        }

        return found.plan.unknown.len > 0 and !found.plan.newer_compatible();
    }
};

/// The gate's verdict without the gate: its migrations and the tables it makes are run on a
/// copy of the database in memory, and the copy's shape is compared. The file is only read.
pub fn status(connection: *db.Db, runtime: *db.Runtime, arena: std.mem.Allocator) !Status {
    std.debug.assert(connection.transaction_depth == 0);
    std.debug.assert(runtime.open_count >= 1);

    var expected = try gate.expected_database(runtime);
    defer expected.close();

    const recorded = try gate.recorded_migrations(connection, arena);
    const has_settings = try db.schema.has_table(connection, "settings");
    const plan = try db.migration.plan_of(arena, registry.SDK.migrations, recorded);
    const newer = plan.unknown.len > 0 and !plan.newer_compatible();
    const release = if (has_settings)
        try settings.get(connection, arena, gate.release_key)
    else
        null;
    var found: Status = .{
        .release = release,
        .plan = plan,
        .differences = &.{},
    };

    // The gate refuses a newer database before it migrates, and makes a database without
    // settings anew: there is nothing to rehearse.
    if (newer or !has_settings) {
        found.differences = try differences_of(&expected, connection, arena);
        return found;
    }

    var copy = try copy_in_memory(connection, runtime, arena);
    defer copy.close();

    rehearse(&copy, plan) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            found.failure = @errorName(err);
            found.differences = try differences_of(&expected, connection, arena);
            return found;
        },
    };

    found.differences = try differences_of(&expected, &copy, arena);

    return found;
}

fn differences_of(
    expected: *db.Db,
    connection: *db.Db,
    arena: std.mem.Allocator,
) ![]const db.shape.Difference {
    std.debug.assert(expected != connection);
    std.debug.assert(connection.transaction_depth <= 1);

    return db.shape.compare(
        arena,
        try db.shape.read(expected, arena),
        try db.shape.read(connection, arena),
    );
}

/// The database's pages copied into a database of its own in memory.
fn copy_in_memory(connection: *db.Db, runtime: *db.Runtime, arena: std.mem.Allocator) !db.Db {
    std.debug.assert(connection.transaction_depth == 0);
    std.debug.assert(runtime.open_count >= 1);

    const image = try connection.serialize(arena);

    std.debug.assert(image.len >= 100);

    // The file's header says WAL (2 at bytes 18 and 19), which a database in memory cannot
    // keep: the copy reads as a plain journal one.
    if (image[18] == 2) {
        image[18] = 1;
        image[19] = 1;
    }

    var copy = try db.open(runtime, ":memory:");
    errdefer copy.close();

    try copy.deserialize(image);

    return copy;
}

/// What the gate does on opening it, before it checks the shape: the pending migrations
/// run, the superseded forgotten, the missing tables made.
fn rehearse(copy: *db.Db, plan: db.migration.Plan) !void {
    std.debug.assert(copy.transaction_depth == 0);
    std.debug.assert(plan.pending.len <= db.migration.migrations_max);

    try copy.exec("PRAGMA foreign_keys = OFF");

    var transaction = try copy.transaction();
    defer transaction.rollback();

    try db.migration.run(copy, plan, rehearsal_ms);
    try gate.apply_schema(copy);
    try transaction.commit();
}
