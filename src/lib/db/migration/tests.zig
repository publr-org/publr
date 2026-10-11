const std = @import("std");
const db = @import("../../db.zig");
const migration = @import("../migration.zig");

const Migration = migration.Migration;

const AddNote = struct {
    pub const one_way = false;

    pub fn up(connection: *db.Db) db.Error!void {
        if (!try db.schema.has_column(connection, "views", "note")) {
            try connection.exec("ALTER TABLE views ADD COLUMN note TEXT");
        }
    }
};

const DropNote = struct {
    pub const one_way = true;

    pub fn up(connection: *db.Db) db.Error!void {
        if (try db.schema.has_column(connection, "views", "note")) {
            try connection.exec("ALTER TABLE views DROP COLUMN note");
        }
    }
};

const add_note = Migration.of("publr", "0.4.0", AddNote, "add note");
const add_note_unreleased = Migration.of("publr", migration.unreleased, AddNote, "add note");
const add_note_edited = Migration.of("publr", migration.unreleased, AddNote, "add note, v2");
const drop_note = Migration.of("publr", "0.5.0", DropNote, "drop note");

fn now_ms() i64 {
    return 1_760_000_000_000;
}

fn plan_for(
    connection: *db.Db,
    arena: std.mem.Allocator,
    known: []const Migration,
) !migration.Plan {
    return migration.plan_of(arena, known, try migration.applied(connection, arena));
}

fn run_all(connection: *db.Db, plan: migration.Plan) !void {
    std.debug.assert(connection.transaction_depth == 0);

    var transaction = try connection.transaction();
    defer transaction.rollback();

    try migration.run(connection, plan, now_ms());
    try transaction.commit();
}

test "a fresh database records every migration and has nothing pending" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;
    const known = [_]Migration{ add_note, drop_note };

    var transaction = try connection.transaction();
    defer transaction.rollback();

    try migration.record_all(connection, &known, now_ms());
    try transaction.commit();

    const plan = try plan_for(connection, arena, &known);

    try std.testing.expect(!plan.changes());
    try std.testing.expectEqual(@as(usize, 0), plan.unknown.len);
}

test "an older database runs what it lacks, in order, once" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;
    const known = [_]Migration{ add_note, drop_note };

    const first = try plan_for(connection, arena, &known);

    try std.testing.expectEqual(@as(usize, 2), first.pending.len);
    try std.testing.expectEqualStrings("0.4.0", first.pending[0].name);

    try run_all(connection, first);

    try std.testing.expect(!try db.schema.has_column(connection, "views", "note"));
    try std.testing.expect(!(try plan_for(connection, arena, &known)).changes());
}

test "an unreleased migration runs again when its file changes" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;

    try run_all(connection, try plan_for(connection, arena, &.{add_note_unreleased}));
    try std.testing.expect(!(try plan_for(connection, arena, &.{add_note_unreleased})).changes());

    const edited = try plan_for(connection, arena, &.{add_note_edited});

    try std.testing.expectEqual(@as(usize, 1), edited.pending.len);
    try run_all(connection, edited);
    try std.testing.expect(!(try plan_for(connection, arena, &.{add_note_edited})).changes());
}

test "a released migration supersedes the unreleased one it became" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;

    try run_all(connection, try plan_for(connection, arena, &.{add_note_unreleased}));

    const released = try plan_for(connection, arena, &.{add_note});

    try std.testing.expectEqual(@as(usize, 1), released.superseded.len);
    try std.testing.expectEqual(@as(usize, 0), released.unknown.len);
    try run_all(connection, released);

    const rows = try migration.applied(connection, arena);

    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("0.4.0", rows[0].name);
}

test "a database one step newer is fine, unless that step was one-way or there were two" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;

    try run_all(connection, try plan_for(connection, arena, &.{add_note}));

    const one_step = try plan_for(connection, arena, &.{});

    try std.testing.expectEqual(@as(usize, 1), one_step.unknown.len);
    try std.testing.expect(one_step.newer_compatible());

    try run_all(connection, try plan_for(connection, arena, &.{ add_note, drop_note }));

    try std.testing.expect(!(try plan_for(connection, arena, &.{add_note})).newer_compatible());
    try std.testing.expect(!(try plan_for(connection, arena, &.{})).newer_compatible());
}
