//! `ledger_accounts`: one row per ledger account, found by its owner, name, holder, key and
//! unit. Never removed; only its totals and its closed flag change.
const std = @import("std");
const db = @import("../lib/db.zig");
const ids = @import("../lib/id.zig");
const next_id = @import("next_id.zig");

pub const Error = db.Error || error{OutOfMemory};

/// A page of accounts at most.
pub const page_max: u32 = 200;

pub const Row = struct {
    id: []const u8,
    owner: []const u8,
    name: []const u8,
    /// `record`, `person` or empty for none.
    holder_kind: []const u8,
    holder: []const u8,
    key: []const u8,
    unit: []const u8,
    kind: []const u8,
    limit_kept: []const u8,
    debits_posted: i64,
    credits_posted: i64,
    debits_pending: i64,
    credits_pending: i64,
    closed: bool,
    created_at: i64,
};

const columns = "id, owner, name, holder_kind, holder, key, unit, kind, limit_kept, " ++
    "debits_posted, credits_posted, debits_pending, credits_pending, closed, created_at";

/// What an account is found by.
pub const Identity = struct {
    owner: []const u8,
    name: []const u8,
    holder_kind: []const u8 = "",
    holder: []const u8 = "",
    key: []const u8 = "",
    unit: []const u8,
};

pub fn find(connection: *db.Db, arena: std.mem.Allocator, identity: Identity) Error!?Row {
    std.debug.assert(identity.owner.len > 0);
    std.debug.assert(identity.unit.len > 0);

    var select = try connection.prepare("SELECT " ++ columns ++ " FROM ledger_accounts " ++
        "WHERE owner = ?1 AND name = ?2 AND holder_kind = ?3 AND holder = ?4 AND key = ?5 " ++
        "AND unit = ?6");
    defer select.finalize();

    try select.bind_text(1, identity.owner);
    try select.bind_text(2, identity.name);
    try select.bind_text(3, identity.holder_kind);
    try select.bind_text(4, identity.holder);
    try select.bind_text(5, identity.key);
    try select.bind_text(6, identity.unit);

    if (!try select.step()) {
        return null;
    }

    return try select.read(Row, arena);
}

pub fn get(connection: *db.Db, arena: std.mem.Allocator, id: []const u8) Error!?Row {
    std.debug.assert(id.len > 0);
    std.debug.assert(id.len <= 1024);

    var select = try connection.prepare("SELECT " ++ columns ++
        " FROM ledger_accounts WHERE id = ?1");
    defer select.finalize();

    try select.bind_text(1, id);

    if (!try select.step()) {
        return null;
    }

    return try select.read(Row, arena);
}

pub const Opening = struct {
    identity: Identity,
    kind: []const u8,
    limit_kept: []const u8,
    now_ms: i64,
};

/// Opens an account; answers its id.
pub fn insert(
    connection: *db.Db,
    io: std.Io,
    arena: std.mem.Allocator,
    opening: Opening,
) Error![]const u8 {
    std.debug.assert(opening.identity.name.len > 0);
    std.debug.assert(opening.now_ms >= 0);

    var buffer: [ids.len]u8 = undefined;
    const id = try arena.dupe(u8, try next_id.next(
        "ledger_accounts",
        connection,
        io,
        opening.now_ms,
        &buffer,
    ));
    const identity = opening.identity;
    var insert_row = try connection.prepare("INSERT INTO ledger_accounts (id, owner, name, " ++
        "holder_kind, holder, key, unit, kind, limit_kept, created_at) " ++
        "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)");
    defer insert_row.finalize();

    try insert_row.bind_text(1, id);
    try insert_row.bind_text(2, identity.owner);
    try insert_row.bind_text(3, identity.name);
    try insert_row.bind_text(4, identity.holder_kind);
    try insert_row.bind_text(5, identity.holder);
    try insert_row.bind_text(6, identity.key);
    try insert_row.bind_text(7, identity.unit);
    try insert_row.bind_text(8, opening.kind);
    try insert_row.bind_text(9, opening.limit_kept);
    try insert_row.bind_int(10, opening.now_ms);
    try insert_row.exec();

    return id;
}

pub const Totals = struct {
    debits_posted: i64,
    credits_posted: i64,
    debits_pending: i64,
    credits_pending: i64,
};

pub fn save_totals(connection: *db.Db, id: []const u8, totals: Totals) db.Error!void {
    std.debug.assert(id.len > 0);
    std.debug.assert(totals.debits_posted >= 0 and totals.credits_pending >= 0);

    var update = try connection.prepare("UPDATE ledger_accounts SET debits_posted = ?2, " ++
        "credits_posted = ?3, debits_pending = ?4, credits_pending = ?5 WHERE id = ?1");
    defer update.finalize();

    try update.bind_text(1, id);
    try update.bind_int(2, totals.debits_posted);
    try update.bind_int(3, totals.credits_posted);
    try update.bind_int(4, totals.debits_pending);
    try update.bind_int(5, totals.credits_pending);
    try update.exec();
}

pub fn set_closed(connection: *db.Db, id: []const u8, closed: bool) db.Error!void {
    std.debug.assert(id.len > 0);
    std.debug.assert(id.len <= 1024);

    var update = try connection.prepare("UPDATE ledger_accounts SET closed = ?2 WHERE id = ?1");
    defer update.finalize();

    try update.bind_text(1, id);
    try update.bind_int(2, @intFromBool(closed));
    try update.exec();
}

/// What a list of accounts is narrowed to; an empty part narrows nothing.
pub const Filter = struct {
    owner: []const u8 = "",
    name: []const u8 = "",
    holder: []const u8 = "",
    unit: []const u8 = "",
    /// Owners the reader may see; empty: every owner.
    owners: []const []const u8 = &.{},
    /// Ids after this one, for the next page.
    after: []const u8 = "",
};

/// Accounts in the order they were opened, a page at a time.
pub fn list(
    connection: *db.Db,
    arena: std.mem.Allocator,
    filter: Filter,
    limit: u32,
) Error![]const Row {
    std.debug.assert(limit > 0 and limit <= page_max);
    std.debug.assert(filter.owners.len <= 256);

    var sql: std.Io.Writer.Allocating = .init(arena);

    sql.writer.writeAll("SELECT " ++ columns ++ " FROM ledger_accounts WHERE " ++
        "(?1 = '' OR owner = ?1) AND (?2 = '' OR name = ?2) AND (?3 = '' OR holder = ?3) " ++
        "AND (?4 = '' OR unit = ?4 OR unit LIKE ?4 || '/%') AND id > ?5") catch
        return error.OutOfMemory;

    if (filter.owners.len > 0) {
        sql.writer.writeAll(" AND owner IN (") catch return error.OutOfMemory;

        for (filter.owners, 0..) |_, index| {
            const comma = if (index > 0) ", " else "";

            sql.writer.print("{s}?{d}", .{ comma, index + 7 }) catch return error.OutOfMemory;
        }

        sql.writer.writeAll(")") catch return error.OutOfMemory;
    }

    sql.writer.writeAll(" ORDER BY id LIMIT ?6") catch return error.OutOfMemory;

    var select = try connection.prepare_dynamic(sql.written());
    defer select.finalize();

    try select.bind_text(1, filter.owner);
    try select.bind_text(2, filter.name);
    try select.bind_text(3, filter.holder);
    try select.bind_text(4, filter.unit);
    try select.bind_text(5, filter.after);
    try select.bind_int(6, limit);

    for (filter.owners, 0..) |owner, index| {
        try select.bind_text(@intCast(index + 7), owner);
    }

    var rows: std.ArrayList(Row) = .empty;

    while (try select.step()) {
        rows.append(arena, try select.read(Row, arena)) catch return error.OutOfMemory;
    }

    return rows.items;
}

/// Each unit's posted and pending debits and credits over every account.
pub const UnitSums = struct {
    unit: []const u8,
    debits_posted: i64,
    credits_posted: i64,
    debits_pending: i64,
    credits_pending: i64,
};

pub fn unit_sums(connection: *db.Db, arena: std.mem.Allocator) Error![]const UnitSums {
    std.debug.assert(page_max > 0);

    var select = try connection.prepare("SELECT unit, total(debits_posted), " ++
        "total(credits_posted), total(debits_pending), total(credits_pending) " ++
        "FROM ledger_accounts GROUP BY unit ORDER BY unit");
    defer select.finalize();

    const Raw = struct {
        unit: []const u8,
        debits_posted: f64,
        credits_posted: f64,
        debits_pending: f64,
        credits_pending: f64,
    };
    var rows: std.ArrayList(UnitSums) = .empty;

    while (try select.step()) {
        const raw = try select.read(Raw, arena);

        rows.append(arena, .{
            .unit = raw.unit,
            .debits_posted = @intFromFloat(raw.debits_posted),
            .credits_posted = @intFromFloat(raw.credits_posted),
            .debits_pending = @intFromFloat(raw.debits_pending),
            .credits_pending = @intFromFloat(raw.credits_pending),
        }) catch return error.OutOfMemory;
    }

    std.debug.assert(rows.items.len <= std.math.maxInt(u32));

    return rows.items;
}

test "an account opens once per identity; its totals change, nothing else" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;
    const identity: Identity = .{
        .owner = "loyalty",
        .name = "held",
        .holder_kind = "person",
        .holder = "u1",
        .unit = "loyalty.points",
    };
    const id = try insert(connection, std.testing.io, arena, .{
        .identity = identity,
        .kind = "liability",
        .limit_kept = "never_below_zero",
        .now_ms = 1_790_000_000_000,
    });

    try std.testing.expectEqualStrings(id, (try find(connection, arena, identity)).?.id);
    try std.testing.expectError(error.Constraint, insert(connection, std.testing.io, arena, .{
        .identity = identity,
        .kind = "liability",
        .limit_kept = "none",
        .now_ms = 1_790_000_000_001,
    }));
    try save_totals(connection, id, .{
        .debits_posted = 0,
        .credits_posted = 500,
        .debits_pending = 100,
        .credits_pending = 0,
    });

    const read = (try get(connection, arena, id)).?;

    try std.testing.expectEqual(@as(i64, 500), read.credits_posted);
    try std.testing.expectEqual(@as(usize, 1), (try list(connection, arena, .{
        .unit = "loyalty.points",
    }, 50)).len);
    try std.testing.expectEqual(@as(usize, 0), (try list(connection, arena, .{
        .owners = &.{"orders"},
    }, 50)).len);
}
