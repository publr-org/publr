//! `ledger_transfers`: one row per transfer, never changed or removed. A hold's post, void or
//! expiry is a row of its own pointing at the hold; a reversal points at what it undoes; a
//! conversion's two legs point at each other.
const std = @import("std");
const db = @import("../lib/db.zig");
const ids = @import("../lib/id.zig");
const next_id = @import("next_id.zig");

pub const Error = db.Error || error{OutOfMemory};

pub const page_max: u32 = 200;

pub const Row = struct {
    id: []const u8,
    maker: []const u8,
    /// The maker's own id for it; empty for a hold's post, void or expiry.
    maker_id: []const u8,
    /// 0, or 1 for a conversion's second leg.
    leg: i64,
    /// The plugin it was made for, when another's account was handed over; empty otherwise.
    made_for: []const u8,
    action: []const u8,
    debit: []const u8,
    credit: []const u8,
    unit: []const u8,
    amount: i64,
    reason: []const u8,
    hold: []const u8,
    reverses: []const u8,
    pair: []const u8,
    rate: i64,
    source: []const u8,
    chain: []const u8,
    about: []const u8,
    detail: []const u8,
    author: []const u8,
    expires_at: ?i64,
    happened_at: i64,
    posted_at: i64,
    debit_after: i64,
    credit_after: i64,
};

const columns = "id, maker, maker_id, leg, made_for, action, debit, credit, unit, amount, " ++
    "reason, hold, reverses, pair, rate, source, chain, about, detail, author, expires_at, " ++
    "happened_at, posted_at, debit_after, credit_after";

/// A transfer as written; `id` is made here.
pub fn insert(connection: *db.Db, io: std.Io, arena: std.mem.Allocator, row: Row) Error![]const u8 {
    std.debug.assert(row.amount > 0);
    std.debug.assert(!std.mem.eql(u8, row.debit, row.credit));

    var buffer: [ids.len]u8 = undefined;
    const made = try next_id.next("ledger_transfers", connection, io, row.posted_at, &buffer);
    const id = try arena.dupe(u8, made);
    var insert_row = try connection.prepare("INSERT INTO ledger_transfers (" ++ columns ++
        ") VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, " ++
        "?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25)");
    defer insert_row.finalize();

    const texts = [_][]const u8{
        id, row.maker, row.maker_id,
    };

    for (texts, 1..) |text, index| {
        try insert_row.bind_text(@intCast(index), text);
    }

    try insert_row.bind_int(4, row.leg);

    const middle = [_][]const u8{
        row.made_for, row.action, row.debit, row.credit, row.unit,
    };

    for (middle, 5..) |text, index| {
        try insert_row.bind_text(@intCast(index), text);
    }

    try insert_row.bind_int(10, row.amount);

    const rest = [_][]const u8{ row.reason, row.hold, row.reverses, row.pair };

    for (rest, 11..) |text, index| {
        try insert_row.bind_text(@intCast(index), text);
    }

    try insert_row.bind_int(15, row.rate);

    const chain = if (row.chain.len > 0) row.chain else id;
    const late = [_][]const u8{ row.source, chain, row.about, row.detail, row.author };

    for (late, 16..) |text, index| {
        try insert_row.bind_text(@intCast(index), text);
    }

    try bind_time(&insert_row, 21, row.expires_at);
    try insert_row.bind_int(22, row.happened_at);
    try insert_row.bind_int(23, row.posted_at);
    try insert_row.bind_int(24, row.debit_after);
    try insert_row.bind_int(25, row.credit_after);
    try insert_row.exec();

    return id;
}

pub fn get(connection: *db.Db, arena: std.mem.Allocator, id: []const u8) Error!?Row {
    std.debug.assert(id.len > 0);
    std.debug.assert(id.len <= 1024);

    var select = try connection.prepare("SELECT " ++ columns ++
        " FROM ledger_transfers WHERE id = ?1");
    defer select.finalize();

    try select.bind_text(1, id);

    return one(&select, arena);
}

/// The transfer a maker made under its own id (and leg).
pub fn by_maker(
    connection: *db.Db,
    arena: std.mem.Allocator,
    maker: []const u8,
    maker_id: []const u8,
    leg: i64,
) Error!?Row {
    std.debug.assert(maker.len > 0);
    std.debug.assert(maker_id.len > 0);

    var select = try connection.prepare("SELECT " ++ columns ++ " FROM ledger_transfers " ++
        "WHERE maker = ?1 AND maker_id = ?2 AND leg = ?3");
    defer select.finalize();

    try select.bind_text(1, maker);
    try select.bind_text(2, maker_id);
    try select.bind_int(3, leg);

    return one(&select, arena);
}

/// What settled a hold (its post, void or expiry); null while it is open.
pub fn settle_of(connection: *db.Db, arena: std.mem.Allocator, hold: []const u8) Error!?Row {
    std.debug.assert(hold.len > 0);
    std.debug.assert(hold.len <= 1024);

    var select = try connection.prepare("SELECT " ++ columns ++
        " FROM ledger_transfers WHERE hold = ?1");
    defer select.finalize();

    try select.bind_text(1, hold);

    return one(&select, arena);
}

/// How much of a transfer its reversals undid.
pub fn reversed(connection: *db.Db, transfer: []const u8) db.Error!i64 {
    std.debug.assert(transfer.len > 0);
    std.debug.assert(transfer.len <= 1024);

    var select = try connection.prepare("SELECT coalesce(sum(amount), 0) FROM " ++
        "ledger_transfers WHERE reverses = ?1");
    defer select.finalize();

    try select.bind_text(1, transfer);
    _ = try select.step();

    return select.read_int();
}

/// The reversals of a transfer, oldest first.
pub fn reversals_of(
    connection: *db.Db,
    arena: std.mem.Allocator,
    transfer: []const u8,
) Error![]const Row {
    std.debug.assert(transfer.len > 0);
    std.debug.assert(transfer.len <= 1024);

    var select = try connection.prepare("SELECT " ++ columns ++
        " FROM ledger_transfers WHERE reverses = ?1 ORDER BY id LIMIT 200");
    defer select.finalize();

    try select.bind_text(1, transfer);

    return all(&select, arena, page_max);
}

/// What narrows a history or a search; empty parts narrow nothing.
pub const Filter = struct {
    about: []const u8 = "",
    detail: []const u8 = "",
    from_ms: ?i64 = null,
    to_ms: ?i64 = null,
    /// Ids before this one: the next page back.
    before: []const u8 = "",
};

/// An account's transfers, newest first, a page at a time.
pub fn history(
    connection: *db.Db,
    arena: std.mem.Allocator,
    account: []const u8,
    filter: Filter,
    limit: u32,
) Error![]const Row {
    std.debug.assert(account.len > 0);
    std.debug.assert(limit > 0 and limit <= page_max);

    var select = try connection.prepare("SELECT " ++ columns ++ " FROM ledger_transfers " ++
        "WHERE id IN (SELECT id FROM ledger_transfers WHERE debit = ?1 AND (?2 = '' OR id < ?2) " ++
        "UNION ALL SELECT id FROM ledger_transfers WHERE credit = ?1 AND (?2 = '' OR id < ?2)) " ++
        "AND (?3 = '' OR about = ?3) AND (?4 IS NULL OR happened_at >= ?4) " ++
        "AND (?5 IS NULL OR happened_at < ?5) ORDER BY id DESC LIMIT ?6");
    defer select.finalize();

    try select.bind_text(1, account);
    try select.bind_text(2, filter.before);
    try select.bind_text(3, filter.about);
    try bind_time(&select, 4, filter.from_ms);
    try bind_time(&select, 5, filter.to_ms);
    try select.bind_int(6, limit);

    return all(&select, arena, limit);
}

/// What narrows a search. At least one of `about`, `detail`, `account` and `name` is given:
/// each is read through an index. `reason` narrows what those found.
pub const Search = struct {
    about: []const u8 = "",
    detail: []const u8 = "",
    reason: []const u8 = "",
    /// Transfers on this account, either side.
    account: []const u8 = "",
    /// Transfers on `owner`'s accounts named `name`, either side.
    owner: []const u8 = "",
    name: []const u8 = "",
    /// Only transfers past this one: after it oldest first, before it newest first.
    past: []const u8 = "",
    newest: bool = false,
};

const named_accounts = "(SELECT id FROM ledger_accounts WHERE owner = ?6 AND name = ?7)";
const on_account = "(SELECT id FROM ledger_transfers WHERE debit = ?5 UNION ALL " ++
    "SELECT id FROM ledger_transfers WHERE credit = ?5)";

/// The filters of `filter` as SQL, each only when it is given: a filter left out is no part
/// of the statement, so the ones given are read through their indexes. The partial indexes
/// on `about` and `detail` take only rows that hold one, which the statement says too.
fn narrowed(sql: *std.Io.Writer, filter: Search, comptime table: []const u8) !void {
    std.debug.assert(filter.name.len == 0 or filter.owner.len > 0);

    if (filter.about.len > 0) {
        try sql.writeAll(" AND " ++ table ++ "about = ?1 AND " ++ table ++ "about != ''");
    }

    if (filter.detail.len > 0) {
        try sql.writeAll(" AND " ++ table ++ "detail = ?2 AND " ++ table ++ "detail != ''");
    }

    if (filter.reason.len > 0) {
        try sql.writeAll(" AND " ++ table ++ "reason = ?4");
    }

    if (filter.account.len > 0) {
        try sql.writeAll(" AND " ++ table ++ "id IN " ++ on_account);
    }

    if (filter.name.len > 0) {
        try sql.writeAll(" AND (" ++ table ++ "debit IN " ++ named_accounts ++ " OR " ++
            table ++ "credit IN " ++ named_accounts ++ ")");
    }
}

fn bind_search(select: *db.Statement, filter: Search) db.Error!void {
    std.debug.assert(filter.name.len == 0 or filter.owner.len > 0);

    try select.bind_text(1, filter.about);
    try select.bind_text(2, filter.detail);
    try select.bind_text(3, filter.past);
    try select.bind_text(4, filter.reason);
    try select.bind_text(5, filter.account);
    try select.bind_text(6, filter.owner);
    try select.bind_text(7, filter.name);
}

/// The transfers `filter` takes, a page at a time: oldest first, or newest first.
pub fn search(
    connection: *db.Db,
    arena: std.mem.Allocator,
    filter: Search,
    limit: u32,
) Error![]const Row {
    std.debug.assert(filter.about.len > 0 or filter.detail.len > 0 or
        filter.account.len > 0 or filter.name.len > 0);
    std.debug.assert(limit > 0 and limit <= page_max * 10);

    var sql: std.Io.Writer.Allocating = .init(arena);
    const text = &sql.writer;

    text.writeAll("SELECT " ++ columns ++ " FROM ledger_transfers WHERE 1") catch {
        return error.OutOfMemory;
    };
    narrowed(text, filter, "") catch return error.OutOfMemory;

    if (filter.past.len > 0) {
        text.writeAll(if (filter.newest) " AND id < ?3" else " AND id > ?3") catch {
            return error.OutOfMemory;
        };
    }

    const ordered = if (filter.newest) " ORDER BY id DESC LIMIT ?8" else " ORDER BY id LIMIT ?8";

    text.writeAll(ordered) catch return error.OutOfMemory;

    var select = try connection.prepare_dynamic(sql.written());
    defer select.finalize();

    try bind_search(&select, filter);
    try select.bind_int(8, limit);

    return all(&select, arena, limit);
}

/// The posted balance of an account after its last posted transfer at or before `at_ms`;
/// null when none had reached it then.
pub fn balance_at(connection: *db.Db, account: []const u8, at_ms: i64) db.Error!?i64 {
    std.debug.assert(account.len > 0);
    std.debug.assert(at_ms >= 0);

    var select = try connection.prepare("SELECT CASE WHEN debit = ?1 THEN debit_after " ++
        "ELSE credit_after END FROM ledger_transfers WHERE id IN (SELECT id FROM " ++
        "ledger_transfers WHERE debit = ?1 UNION ALL SELECT id FROM ledger_transfers WHERE " ++
        "credit = ?1) AND posted_at <= ?2 ORDER BY id DESC LIMIT 1");
    defer select.finalize();

    try select.bind_text(1, account);
    try select.bind_int(2, at_ms);

    if (!try select.step()) {
        return null;
    }

    return select.read_int();
}

/// Sums per reason and unit over the transfers that match, on one account's sides or the
/// accounts of one name, or (neither given) each transfer once. `detail` is the finer record
/// the sums are of when they were asked for `details`, else empty.
pub const Sum = struct {
    reason: []const u8,
    unit: []const u8,
    detail: []const u8 = "",
    debits_posted: i64,
    credits_posted: i64,
    debits_pending: i64,
    credits_pending: i64,
};

pub const SumFilter = struct {
    about: []const u8 = "",
    detail: []const u8 = "",
    reason: []const u8 = "",
    account: []const u8 = "",
    owner: []const u8 = "",
    name: []const u8 = "",
    from_ms: ?i64 = null,
    to_ms: ?i64 = null,
    /// One sum per finer record named here too: a page of an order's charges, each with
    /// its own. Up to `details_max`.
    details: []const []const u8 = &.{},
    /// The sums after this one, in the order they are read: a page after the one before.
    after: ?SumKey = null,
    /// The most sums read.
    limit: u32 = sums_max + 1,
};

/// Where a sum lies in the order sums are read: by detail (when asked per detail), reason
/// and unit.
pub const SumKey = struct {
    detail: []const u8,
    reason: []const u8,
    unit: []const u8,
};

/// The placeholders of `SumKey`: past every other.
const after_first: u32 = details_first + details_max;

pub const details_max: u32 = 200;

/// How many sums one read answers: past it the read is refused, never cut short.
pub const sums_max: u32 = 2000;

const sums_head =
    \\SELECT reason, unit, {s},
    \\  total(CASE WHEN posts AND on_debit THEN amount ELSE 0 END),
    \\  total(CASE WHEN posts AND on_credit THEN amount ELSE 0 END),
    \\  total(CASE WHEN open AND on_debit THEN amount ELSE 0 END),
    \\  total(CASE WHEN open AND on_credit THEN amount ELSE 0 END)
    \\FROM (SELECT t.reason, t.unit, t.detail, t.amount,
    \\  t.action IN ('transfer', 'post', 'reverse', 'convert') AS posts,
    \\  t.action = 'hold' AND NOT EXISTS
    \\    (SELECT 1 FROM ledger_transfers s WHERE s.hold = t.id) AS open,
    \\  {s} AS on_debit, {s} AS on_credit
    \\  FROM ledger_transfers t WHERE 1
;

/// Each matching transfer once, with whether it lands on the debit or credit side of what
/// is asked about: the account, the accounts of the name, or both sides with neither.
pub fn sums(connection: *db.Db, arena: std.mem.Allocator, filter: SumFilter) Error![]const Sum {
    std.debug.assert(filter.about.len > 0 or filter.detail.len > 0 or
        filter.account.len > 0 or filter.name.len > 0 or filter.details.len > 0);
    std.debug.assert(filter.name.len == 0 or filter.owner.len > 0);
    std.debug.assert(filter.details.len <= details_max);

    const search_filter: Search = .{
        .about = filter.about,
        .detail = filter.detail,
        .reason = filter.reason,
        .account = filter.account,
        .owner = filter.owner,
        .name = filter.name,
    };
    const sides: [2][]const u8 = if (filter.account.len > 0)
        .{ "t.debit = ?5", "t.credit = ?5" }
    else if (filter.name.len > 0)
        .{ "t.debit IN " ++ named_accounts, "t.credit IN " ++ named_accounts }
    else
        .{ "1", "1" };
    var sql: std.Io.Writer.Allocating = .init(arena);
    const text = &sql.writer;

    const per_detail = filter.details.len > 0;
    const grouped: []const u8 = if (per_detail) "detail" else "''";

    text.print(sums_head, .{ grouped, sides[0], sides[1] }) catch return error.OutOfMemory;
    narrowed(text, search_filter, "t.") catch return error.OutOfMemory;
    among(text, filter.details.len) catch return error.OutOfMemory;

    // Every placeholder of the key is in the text, the detail too, so all three bind.
    if (filter.after != null and per_detail) {
        text.print(" AND (t.detail, t.reason, t.unit) > (?{d}, ?{d}, ?{d})", .{
            after_first,
            after_first + 1,
            after_first + 2,
        }) catch return error.OutOfMemory;
    } else if (filter.after != null) {
        text.print(" AND (t.reason, t.unit) > (?{d}, ?{d}) AND ?{d} = ''", .{
            after_first + 1,
            after_first + 2,
            after_first,
        }) catch return error.OutOfMemory;
    }

    text.writeAll(" AND (?3 IS NULL OR t.happened_at >= ?3) AND " ++
        "(?8 IS NULL OR t.happened_at < ?8)) ") catch return error.OutOfMemory;
    text.writeAll(if (per_detail)
        "GROUP BY detail, reason, unit ORDER BY detail, reason, unit LIMIT ?9"
    else
        "GROUP BY reason, unit ORDER BY reason, unit LIMIT ?9") catch return error.OutOfMemory;

    var select = try connection.prepare_dynamic(sql.written());
    defer select.finalize();

    try bind_search(&select, search_filter);
    try bind_time(&select, 3, filter.from_ms);
    try bind_time(&select, 8, filter.to_ms);
    try select.bind_int(9, filter.limit);

    if (filter.after) |key| {
        try select.bind_text(after_first, key.detail);
        try select.bind_text(after_first + 1, key.reason);
        try select.bind_text(after_first + 2, key.unit);
    }

    for (filter.details, 0..) |detail, index| {
        try select.bind_text(@intCast(details_first + index), detail);
    }

    return summed(&select, arena);
}

/// The first placeholder of the details named.
const details_first: u32 = 10;

/// ` AND t.detail IN (?10, ?11, …)` for `count` details named; nothing for none.
fn among(sql: *std.Io.Writer, count: u64) !void {
    std.debug.assert(count <= details_max);

    if (count == 0) {
        return;
    }

    try sql.writeAll(" AND t.detail != '' AND t.detail IN (");

    for (0..@as(usize, @intCast(count))) |index| {
        try sql.print("{s}?{d}", .{ if (index > 0) ", " else "", details_first + index });
    }

    try sql.writeAll(")");
}

fn summed(select: *db.Statement, arena: std.mem.Allocator) Error![]const Sum {
    const Raw = struct {
        reason: []const u8,
        unit: []const u8,
        detail: []const u8,
        debits_posted: f64,
        credits_posted: f64,
        debits_pending: f64,
        credits_pending: f64,
    };
    var rows: std.ArrayList(Sum) = .empty;

    std.debug.assert(sums_max > 0);

    while (try select.step()) {
        const raw = try select.read(Raw, arena);

        rows.append(arena, .{
            .reason = raw.reason,
            .unit = raw.unit,
            .detail = raw.detail,
            .debits_posted = @intFromFloat(raw.debits_posted),
            .credits_posted = @intFromFloat(raw.credits_posted),
            .debits_pending = @intFromFloat(raw.debits_pending),
            .credits_pending = @intFromFloat(raw.credits_pending),
        }) catch return error.OutOfMemory;
    }

    return rows.items;
}

/// An account whose kept totals differ from what its transfers add up to.
pub const Differing = struct {
    account: []const u8,
    debits_posted: i64,
    credits_posted: i64,
    debits_pending: i64,
    credits_pending: i64,
};

/// Every account whose totals its transfers do not add up to: none, unless there is a bug.
pub fn differing(connection: *db.Db, arena: std.mem.Allocator) Error![]const Differing {
    std.debug.assert(page_max > 0);

    var select = try connection.prepare(
        \\WITH legs AS (
        \\  SELECT debit AS account, amount, 1 AS debit_side,
        \\    action IN ('transfer', 'post', 'reverse', 'convert') AS posts,
        \\    action = 'hold' AND NOT EXISTS
        \\      (SELECT 1 FROM ledger_transfers s WHERE s.hold = t.id) AS open
        \\  FROM ledger_transfers t
        \\  UNION ALL
        \\  SELECT credit, amount, 0,
        \\    action IN ('transfer', 'post', 'reverse', 'convert'),
        \\    action = 'hold' AND NOT EXISTS (SELECT 1 FROM ledger_transfers s WHERE s.hold = t.id)
        \\  FROM ledger_transfers t),
        \\counted AS (SELECT account,
        \\  total(CASE WHEN posts AND debit_side THEN amount ELSE 0 END) AS dp,
        \\  total(CASE WHEN posts AND NOT debit_side THEN amount ELSE 0 END) AS cp,
        \\  total(CASE WHEN open AND debit_side THEN amount ELSE 0 END) AS dq,
        \\  total(CASE WHEN open AND NOT debit_side THEN amount ELSE 0 END) AS cq
        \\  FROM legs GROUP BY account)
        \\SELECT a.id, coalesce(c.dp, 0), coalesce(c.cp, 0), coalesce(c.dq, 0), coalesce(c.cq, 0)
        \\FROM ledger_accounts a LEFT JOIN counted c ON c.account = a.id
        \\WHERE coalesce(c.dp, 0) <> a.debits_posted OR coalesce(c.cp, 0) <> a.credits_posted
        \\  OR coalesce(c.dq, 0) <> a.debits_pending OR coalesce(c.cq, 0) <> a.credits_pending
        \\ORDER BY a.id LIMIT 200
    );
    defer select.finalize();

    const Raw = struct {
        account: []const u8,
        debits_posted: f64,
        credits_posted: f64,
        debits_pending: f64,
        credits_pending: f64,
    };
    var rows: std.ArrayList(Differing) = .empty;

    while (try select.step()) {
        const raw = try select.read(Raw, arena);

        rows.append(arena, .{
            .account = raw.account,
            .debits_posted = @intFromFloat(raw.debits_posted),
            .credits_posted = @intFromFloat(raw.credits_posted),
            .debits_pending = @intFromFloat(raw.debits_pending),
            .credits_pending = @intFromFloat(raw.credits_pending),
        }) catch return error.OutOfMemory;
    }

    return rows.items;
}

fn bind_time(select: *db.Statement, index: u31, value: ?i64) db.Error!void {
    std.debug.assert(index > 0);

    if (value) |at| {
        try select.bind_int(index, at);
    } else {
        try select.bind_null(index);
    }
}

fn one(select: *db.Statement, arena: std.mem.Allocator) Error!?Row {
    std.debug.assert(columns.len > 0);

    if (!try select.step()) {
        return null;
    }

    return try select.read(Row, arena);
}

fn all(select: *db.Statement, arena: std.mem.Allocator, limit: u32) Error![]const Row {
    std.debug.assert(limit > 0);

    var rows: std.ArrayList(Row) = .empty;

    while (try select.step()) {
        rows.append(arena, try select.read(Row, arena)) catch return error.OutOfMemory;
    }

    std.debug.assert(rows.items.len <= limit);

    return rows.items;
}
