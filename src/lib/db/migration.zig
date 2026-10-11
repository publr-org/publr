const std = @import("std");
const db = @import("../db.zig");

/// What `migrations/unreleased.zig` is called until a release names it.
pub const unreleased = "unreleased";
pub const migrations_max: u32 = 1024;

/// One step of the chain: what takes a database from the shape before one release to its
/// own. Self-contained: it never reads `schema.sql` or today's code, so it does the same
/// thing whichever later release runs it.
pub const Migration = struct {
    /// `publr`, or the plugin that owns it.
    source: []const u8,
    /// The release it reaches (`0.4.0`), or `unreleased`.
    name: []const u8,
    /// Drops, renames, retypes or rewrites: the release before cannot run on the result.
    one_way: bool,
    /// The file's text: its SHA-256 is what a database records, so a changed unreleased
    /// migration runs again.
    text: []const u8,
    up: *const fn (connection: *db.Db) db.Error!void,

    /// `Module` declares `pub const one_way: bool` and `pub fn up(*Db) !void`; `text` is
    /// its file, `@embedFile`d.
    pub fn of(
        comptime source: []const u8,
        comptime name: []const u8,
        comptime Module: type,
        comptime text: []const u8,
    ) Migration {
        comptime {
            std.debug.assert(source.len > 0);
            std.debug.assert(text.len > 0);

            if (!@hasDecl(Module, "one_way") or !@hasDecl(Module, "up")) {
                @compileError("migration " ++ source ++ " " ++ name ++
                    ": declare `pub const one_way: bool` and `pub fn up(*Db) !void`");
            }

            return .{
                .source = source,
                .name = name,
                .one_way = Module.one_way,
                .text = text,
                .up = &Module.up,
            };
        }
    }

    pub fn sha256(migration: Migration) [64]u8 {
        std.debug.assert(migration.text.len > 0);
        std.debug.assert(migration.name.len > 0);

        var digest: [32]u8 = undefined;

        std.crypto.hash.sha2.Sha256.hash(migration.text, &digest, .{});

        return std.fmt.bytesToHex(digest, .lower);
    }
};

/// A migration a database records.
pub const Applied = struct {
    source: []const u8,
    name: []const u8,
    sha256: []const u8,
    one_way: bool,
};

/// What opening a database with this build's migrations means for it.
pub const Plan = struct {
    /// To run, in order: never applied, or unreleased and changed since it ran.
    pending: []const Migration,
    /// Recorded by a newer build: this one does not know them.
    unknown: []const Applied,
    /// Recorded before, unreleased, and replaced by what is pending now.
    superseded: []const Applied,

    pub fn changes(plan: Plan) bool {
        std.debug.assert(plan.pending.len <= migrations_max);

        return plan.pending.len > 0 or plan.superseded.len > 0;
    }

    /// Whether this build may run on a database a newer one migrated: by one step at most
    /// per source, and only one that leaves the release before able to run.
    pub fn newer_compatible(plan: Plan) bool {
        std.debug.assert(plan.unknown.len <= migrations_max);

        for (plan.unknown, 0..) |row, index| {
            if (row.one_way) {
                return false;
            }

            for (plan.unknown[0..index]) |earlier| {
                if (std.mem.eql(u8, earlier.source, row.source)) {
                    return false;
                }
            }
        }

        return true;
    }
};

pub fn applied(connection: *db.Db, arena: std.mem.Allocator) ![]const Applied {
    std.debug.assert(migrations_max > 0);
    std.debug.assert(connection.transaction_depth <= 1);

    var select = try connection.prepare(
        "SELECT source, name, sha256, one_way FROM migrations ORDER BY applied_ms, rowid",
    );
    defer select.finalize();

    var rows: std.ArrayList(Applied) = .empty;

    while (try select.step()) {
        if (rows.items.len == migrations_max) {
            return error.TooBig;
        }

        try rows.append(arena, try select.read(Applied, arena));
    }

    return rows.items;
}

pub fn plan_of(
    arena: std.mem.Allocator,
    known: []const Migration,
    recorded: []const Applied,
) !Plan {
    std.debug.assert(known.len <= migrations_max);
    std.debug.assert(recorded.len <= migrations_max);

    var pending: std.ArrayList(Migration) = .empty;
    var unknown: std.ArrayList(Applied) = .empty;
    var superseded: std.ArrayList(Applied) = .empty;

    for (known) |migration| {
        const row = find(recorded, migration.source, migration.name);
        const changed = row != null and
            !std.mem.eql(u8, row.?.sha256, &migration.sha256());

        if (row == null or changed) {
            try pending.append(arena, migration);
        }
    }

    for (recorded) |row| {
        if (find_known(known, row.source, row.name) != null) {
            continue;
        }

        const replaced = std.mem.eql(u8, row.name, unreleased) and
            pending_from(pending.items, row.source);

        try (if (replaced) &superseded else &unknown).append(arena, row);
    }

    return .{
        .pending = pending.items,
        .unknown = unknown.items,
        .superseded = superseded.items,
    };
}

/// Run what is pending, in order, and record it; forget what it superseded. Inside the
/// caller's transaction: all of it lands, or none.
pub fn run(connection: *db.Db, plan: Plan, now_ms: i64) db.Error!void {
    std.debug.assert(connection.transaction_depth >= 1);
    std.debug.assert(now_ms > 0);

    for (plan.pending) |migration| {
        try migration.up(connection);
        try record(connection, migration, now_ms);
    }

    for (plan.superseded) |row| {
        var forget = try connection.prepare(
            "DELETE FROM migrations WHERE source = ?1 AND name = ?2",
        );
        defer forget.finalize();

        try forget.bind_text(1, row.source);
        try forget.bind_text(2, row.name);
        try forget.exec();
    }
}

/// A fresh database already has every migration's result: `schema.sql` is the newest shape.
pub fn record_all(connection: *db.Db, known: []const Migration, now_ms: i64) db.Error!void {
    std.debug.assert(connection.transaction_depth >= 1);
    std.debug.assert(known.len <= migrations_max);

    for (known) |migration| {
        try record(connection, migration, now_ms);
    }
}

fn record(connection: *db.Db, migration: Migration, now_ms: i64) db.Error!void {
    std.debug.assert(migration.source.len > 0);
    std.debug.assert(now_ms > 0);

    var upsert = try connection.prepare(
        "INSERT INTO migrations (source, name, sha256, one_way, applied_ms) " ++
            "VALUES (?1, ?2, ?3, ?4, ?5) ON CONFLICT (source, name) DO UPDATE SET " ++
            "sha256 = excluded.sha256, one_way = excluded.one_way, " ++
            "applied_ms = excluded.applied_ms",
    );
    defer upsert.finalize();

    const digest = migration.sha256();

    try upsert.bind_text(1, migration.source);
    try upsert.bind_text(2, migration.name);
    try upsert.bind_text(3, &digest);
    try upsert.bind_int(4, @intFromBool(migration.one_way));
    try upsert.bind_int(5, now_ms);
    try upsert.exec();
}

fn find(recorded: []const Applied, source: []const u8, name: []const u8) ?Applied {
    std.debug.assert(source.len > 0);
    std.debug.assert(name.len > 0);

    for (recorded) |row| {
        if (std.mem.eql(u8, row.source, source) and std.mem.eql(u8, row.name, name)) {
            return row;
        }
    }

    return null;
}

fn find_known(known: []const Migration, source: []const u8, name: []const u8) ?Migration {
    std.debug.assert(source.len > 0);
    std.debug.assert(name.len > 0);

    for (known) |migration| {
        if (std.mem.eql(u8, migration.source, source) and std.mem.eql(u8, migration.name, name)) {
            return migration;
        }
    }

    return null;
}

fn pending_from(pending: []const Migration, source: []const u8) bool {
    std.debug.assert(source.len > 0);
    std.debug.assert(pending.len <= migrations_max);

    for (pending) |migration| {
        if (std.mem.eql(u8, migration.source, source)) {
            return true;
        }
    }

    return false;
}

test {
    _ = @import("migration/tests.zig");
}
