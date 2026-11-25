const std = @import("std");
const db = @import("../../lib/db.zig");
const auth = @import("../../lib/auth.zig");
const gate = @import("../gate.zig");
const conform = @import("conform.zig");

const now_ms: i64 = 1_760_000_000_000;
const all_transfers = "SELECT count(*) FROM ledger_transfers";
const release = "0.8.0";

/// `ledger_transfers` as a development build made it on 2026-11-24: `maker_id` and `hold`
/// NOT NULL with '' for none, each unique by an index; `note` is a column the release
/// does not have.
const development_table =
    \\DROP TABLE ledger_transfers;
    \\CREATE TABLE ledger_transfers (
    \\    id TEXT PRIMARY KEY, maker TEXT NOT NULL, maker_id TEXT NOT NULL,
    \\    leg INTEGER NOT NULL DEFAULT 0, made_for TEXT NOT NULL DEFAULT '',
    \\    action TEXT NOT NULL, debit TEXT NOT NULL REFERENCES ledger_accounts(id),
    \\    credit TEXT NOT NULL REFERENCES ledger_accounts(id), unit TEXT NOT NULL,
    \\    amount INTEGER NOT NULL, reason TEXT NOT NULL, hold TEXT NOT NULL DEFAULT '',
    \\    reverses TEXT NOT NULL DEFAULT '', pair TEXT NOT NULL DEFAULT '',
    \\    rate INTEGER NOT NULL DEFAULT 0, source TEXT NOT NULL DEFAULT '',
    \\    chain TEXT NOT NULL, about TEXT NOT NULL DEFAULT '', detail TEXT NOT NULL DEFAULT '',
    \\    author TEXT NOT NULL, expires_at INTEGER, happened_at INTEGER NOT NULL,
    \\    posted_at INTEGER NOT NULL, debit_after INTEGER NOT NULL,
    \\    credit_after INTEGER NOT NULL, note TEXT NOT NULL DEFAULT ''
    \\) STRICT;
    \\CREATE UNIQUE INDEX ledger_transfers_maker
    \\    ON ledger_transfers (maker, maker_id, leg) WHERE maker_id != '';
    \\CREATE UNIQUE INDEX ledger_transfers_hold ON ledger_transfers (hold) WHERE hold != '';
    \\INSERT INTO ledger_accounts (id, owner, name, unit, kind, limit_kept, created_at)
    \\    VALUES ('a', 'shop', 'cash', 'PLN', 'asset', 'none', 1),
    \\    ('b', 'shop', 'sales', 'PLN', 'income', 'none', 1);
    \\INSERT INTO ledger_transfers (id, maker, maker_id, action, debit, credit, unit, amount,
    \\    reason, chain, author, happened_at, posted_at, debit_after, credit_after)
    \\    VALUES
    \\    ('t1', 'orders', 'o/1', 'post', 'a', 'b', 'PLN', 100, 'sale', 'c', 'x', 1, 1, 0, 0),
    \\    ('t2', 'tax', 'o/1/tax', 'post', 'a', 'b', 'PLN', 23, 'tax', 'c', 'x', 1, 1, 0, 0);
;

/// A site's database in a scratch folder, made by this release.
const Site = struct {
    scratch: std.testing.TmpDir,
    arena_state: std.heap.ArenaAllocator,
    runtime: db.Runtime,
    connection: db.Db,
    left_out_path: []const u8,

    fn init(site: *Site) !void {
        std.debug.assert(now_ms > 0);

        site.scratch = std.testing.tmpDir(.{});
        site.arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);

        const arena = site.arena_state.allocator();
        const root = try site.scratch.dir.realPathFileAlloc(std.testing.io, ".", arena);
        const db_path = try std.fs.path.joinZ(arena, &.{ root, "publr.db" });

        site.left_out_path = try std.fs.path.join(arena, &.{ root, conform.left_out_name });
        site.runtime = try db.Runtime.init(.{});
        site.connection = try db.open(&site.runtime, db_path);

        var auth_state: auth.State = undefined;
        try auth_state.init(std.testing.allocator, std.testing.io, .{
            .params = auth.password.params_test,
        });
        defer auth_state.deinit();

        const made = try gate.open(
            &site.connection,
            std.testing.io,
            std.testing.allocator,
            &site.runtime,
            &auth_state,
            db_path,
            release,
            now_ms,
            .{
                .backup = false,
            },
        );

        std.debug.assert(made == .fresh);
    }

    fn deinit(site: *Site) void {
        std.debug.assert(site.left_out_path.len > 0);

        site.connection.close();
        site.runtime.deinit();
        site.arena_state.deinit();
        site.scratch.cleanup();
    }

    fn run(site: *Site, dry_run: bool) !conform.Outcome {
        std.debug.assert(site.left_out_path.len > 0);

        return conform.run(&site.connection, site.arena_state.allocator(), .{
            .io = std.testing.io,
            .runtime = &site.runtime,
            .release = release,
            .now_ms = now_ms,
        }, .{
            .dry_run = dry_run,
            .left_out_path = site.left_out_path,
        });
    }

    fn refused(site: *Site) !bool {
        std.debug.assert(site.connection.transaction_depth == 0);

        const arena = site.arena_state.allocator();
        const found = try gate.status(&site.connection, &site.runtime, arena);

        return found.refused();
    }

    fn count(site: *Site, comptime sql: []const u8) !i64 {
        std.debug.assert(sql.len > 0);

        var select = try site.connection.prepare(sql);
        defer select.finalize();

        _ = try select.step();

        return select.read_int();
    }
};

fn changes_of(outcome: conform.Outcome, kind: conform.Change.Kind) u32 {
    std.debug.assert(outcome.refusal == null);

    var found: u32 = 0;

    for (outcome.changes) |change| {
        found += @intFromBool(change.kind == kind);
    }

    return found;
}

test "a database in this release's shape has nothing to do" {
    var site: Site = undefined;
    try site.init();
    defer site.deinit();

    const outcome = try site.run(false);

    try std.testing.expect(outcome.nothing());
    try std.testing.expect(!try site.refused());
}

test "a stricter column and an extra unique index are made this release's, nothing lost" {
    var site: Site = undefined;
    try site.init();
    defer site.deinit();

    try site.connection.exec(development_table);
    try std.testing.expect(try site.refused());

    const planned = try site.run(true);

    try std.testing.expectEqual(@as(u32, 1), changes_of(planned, .rebuild));
    try std.testing.expectEqual(@as(u32, 2), changes_of(planned, .drop));
    try std.testing.expectEqual(@as(u32, 1), changes_of(planned, .nulled));
    try std.testing.expectEqual(@as(usize, 0), planned.left_out.len);
    try std.testing.expect(try site.refused());

    const done = try site.run(false);

    try std.testing.expectEqual(planned.changes.len, done.changes.len);
    try std.testing.expect(!try site.refused());
    try std.testing.expectEqual(@as(i64, 2), try site.count(
        "SELECT count(*) FROM ledger_transfers WHERE maker_id LIKE 'o/1%' AND hold IS NULL",
    ));
    try std.testing.expect((try site.run(false)).nothing());
}

test "a row this release's rules refuse is left out and written down, with lost values" {
    var site: Site = undefined;
    try site.init();
    defer site.deinit();

    try site.connection.exec(development_table);
    try site.connection.exec("UPDATE ledger_transfers SET amount = 0 WHERE id = 't2';" ++
        "UPDATE ledger_transfers SET note = 'kept aside' WHERE id = 't1'");

    const planned = try site.run(true);

    try std.testing.expectEqual(@as(usize, 2), planned.left_out.len);
    try std.testing.expectEqualStrings("ledger_transfers", planned.left_out[0].table);
    try std.testing.expect(planned.left_out[0].column == null);
    try std.testing.expectEqualStrings("note", planned.left_out[1].column.?);
    try std.testing.expectEqual(@as(i64, 2), try site.count(all_transfers));

    _ = try site.run(false);

    try std.testing.expect(!try site.refused());
    try std.testing.expectEqual(@as(i64, 1), try site.count(all_transfers));

    const written = try site.scratch.dir.readFileAlloc(
        std.testing.io,
        conform.left_out_name,
        site.arena_state.allocator(),
        .limited(1 << 20),
    );

    try std.testing.expect(std.mem.indexOf(u8, written, "\"key\":{\"id\":\"t2\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"value\":\"kept aside\"") != null);
}

test "a database a newer release migrated is refused, nothing changed" {
    var site: Site = undefined;
    try site.init();
    defer site.deinit();

    try site.connection.exec(development_table);
    try site.connection.exec("INSERT INTO migrations VALUES ('publr', '9.0.0', 'abc', 1, 1)");

    const outcome = try site.run(false);

    try std.testing.expect(outcome.refusal != null);
    try std.testing.expectEqual(@as(i64, 1), try site.count(
        "SELECT count(*) FROM sqlite_schema WHERE name = 'ledger_transfers_hold'",
    ));
}

test "a database with a migration still to run is one this release opens" {
    var site: Site = undefined;
    try site.init();
    defer site.deinit();

    // As a release before 0.8.0 left it: no ledger, no record of 0.8.0's migration.
    try site.connection.exec("DROP TABLE ledger_transfers; DROP TABLE ledger_accounts;" ++
        "DROP TABLE job_due_internal; DELETE FROM migrations");

    const arena = site.arena_state.allocator();
    const found = try gate.status(&site.connection, &site.runtime, arena);

    try std.testing.expect(found.plan.pending.len > 0);
    try std.testing.expect(!found.refused());
    try std.testing.expect(!try db.schema.has_table(&site.connection, "ledger_transfers"));
    try std.testing.expect((try site.run(true)).nothing());
}
