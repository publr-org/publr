//! The ledger's reads, computed natively: an account's balance (as of a time too), its
//! history, transfers about a record, totals per reason, one transfer, accounts, and the full
//! check. A plugin reads its own accounts, those the plugin that called it handed over, and
//! those of plugins its `ledger.read` grant names; a person reads what their role reaches.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const model = @import("../../model/ledger.zig");
const registry = @import("../../server/registry.zig");
const declared = @import("declared.zig");
const permission = @import("../../model/permission.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const Docs = sdk.operation.Docs;
const AccountRow = store.ledger_accounts.Row;
const TransferRow = store.ledger_transfers.Row;

const example_account = "0190c8a3d2e1000014f2a6b9";
const example_transfer = "0190c8a3d2e2000027c3d4e5";

/// Whether the caller may read accounts `owner` keeps.
pub fn may_read(ctx: *Ctx, owner: []const u8) bool {
    std.debug.assert(owner.len > 0);

    // No plugin's code runs: a person or an agent the operation's grant let in, or core.
    if (ctx.plugin.len == 0 or std.mem.eql(u8, ctx.plugin, store.job_queue.core)) {
        return true;
    }

    if (std.mem.eql(u8, owner, ctx.plugin) or std.mem.eql(u8, owner, ctx.handed_by)) {
        return true;
    }

    const access = switch (ctx.caller) {
        .plugin => |caller| caller.access,
        else => registry.SDK.compiled_access(ctx.plugin),
    } orelse return false;
    const held = access.held_of("ledger.read") orelse return false;

    return permission.contains(held.plugins, owner);
}

/// An account the caller may read; refused (NotYours, NoAccount) otherwise.
pub fn readable(ctx: *Ctx, id: []const u8) Error!AccountRow {
    std.debug.assert(ctx.now_ms >= 0);

    const engine = @import("engine.zig");

    if (id.len == 0 or id.len > model.id_len_max) {
        return engine.refuse(ctx, model.refusals.no_account);
    }

    const row = try store.ledger_accounts.get(ctx.db, ctx.arena, id) orelse {
        return engine.refuse(ctx, model.refusals.no_account);
    };

    if (!may_read(ctx, row.owner)) {
        return engine.refuse(ctx, model.refusals.not_yours);
    }

    depends(ctx, row.id);

    return row;
}

/// A page being drawn for the built site depends on what it read of the ledger.
fn depends(ctx: *Ctx, account: []const u8) void {
    std.debug.assert(account.len > 0);

    if (ctx.reads == null) {
        return;
    }

    var buffer: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&buffer, "ledger:{s}", .{account}) catch return;

    ctx.depends_on(key);
}

fn kind_of(row: AccountRow) model.Kind {
    std.debug.assert(row.kind.len > 0);

    return std.meta.stringToEnum(model.Kind, row.kind) orelse .asset;
}

fn totals_of(row: AccountRow) model.Totals {
    std.debug.assert(row.debits_posted >= 0);

    return .{
        .debits_posted = row.debits_posted,
        .credits_posted = row.credits_posted,
        .debits_pending = row.debits_pending,
        .credits_pending = row.credits_pending,
    };
}

pub const Balance = struct {
    pub const name = "ledger.balance";
    /// Plugin code calls it for whoever the request is for, visitors too, held to the
    /// plugin's own reach.
    pub const plugins_only = true;
    pub const description = "An account's balance";
    pub const details =
        \\Its unit, posted balance, pending holds, what is available once every hold posts,
        \\and its four totals; with `at`, the posted balance as it stood then. Balances are
        \\read on the side the account's kind grows on.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        account: []const u8,
        at: ?i64 = null,
    };
    pub const Out = struct {
        unit: []const u8,
        posted: i64,
        pending: i64,
        available: i64,
        debits_posted: i64,
        credits_posted: i64,
        debits_pending: i64,
        credits_pending: i64,
    };
    pub const example: In = .{
        .account = example_account,
    };
    pub const example_out: Out = .{
        .unit = "loyalty.points",
        .posted = 1200,
        .pending = -500,
        .available = 700,
        .debits_posted = 0,
        .credits_posted = 1200,
        .debits_pending = 500,
        .credits_pending = 0,
    };
    pub const field_docs: Docs(In) = .{
        .account = "The account",
        .at = "A time (ms): the posted balance as it stood then",
    };
    pub const output_docs: Docs(Out) = .{
        .unit = "What it counts",
        .posted = "The posted balance",
        .pending = "Its holds, net",
        .available = "The balance once every hold posts",
        .debits_posted = "Debits posted",
        .credits_posted = "Credits posted",
        .debits_pending = "Debits pending",
        .credits_pending = "Credits pending",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        const row = try readable(ctx, in.account);
        const account_kind = kind_of(row);
        const totals = totals_of(row);
        const posted = if (in.at) |at|
            try store.ledger_transfers.balance_at(ctx.db, row.id, at) orelse 0
        else
            model.posted(account_kind, totals);

        std.debug.assert(row.unit.len > 0);

        return .{
            .unit = row.unit,
            .posted = posted,
            .pending = model.pending(account_kind, totals),
            .available = model.available(account_kind, totals),
            .debits_posted = row.debits_posted,
            .credits_posted = row.credits_posted,
            .debits_pending = row.debits_pending,
            .credits_pending = row.credits_pending,
        };
    }
};

/// A transfer as reads answer it, with its accounts' owners and names and its status.
pub const Shown = struct {
    transfer: []const u8,
    maker: []const u8,
    maker_id: []const u8,
    made_for: []const u8,
    action: []const u8,
    status: model.Status,
    debit: []const u8,
    debit_owner: []const u8,
    debit_name: []const u8,
    credit: []const u8,
    credit_owner: []const u8,
    credit_name: []const u8,
    unit: []const u8,
    amount: i64,
    reason: []const u8,
    reason_label: []const u8,
    /// A post's, void's or expiry's: the hold it settles.
    hold: []const u8,
    /// A hold's: what settled it; empty while open.
    settled_by: []const u8,
    reverses: []const u8,
    /// Its reversals, oldest first: `ledger.get` answers them, the lists leave them out.
    reversals: []const []const u8 = &.{},
    /// A conversion's: its other leg.
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

const example_shown: Shown = .{
    .transfer = example_transfer,
    .maker = "loyalty",
    .maker_id = "earned-1042",
    .made_for = "",
    .action = "transfer",
    .status = .posted,
    .debit = "0190c8a3d2e1000015a7b8c9",
    .debit_owner = "loyalty",
    .debit_name = "given",
    .credit = example_account,
    .credit_owner = "loyalty",
    .credit_name = "held",
    .unit = "loyalty.points",
    .amount = 500,
    .reason = "earned",
    .reason_label = "Earned on an order",
    .hold = "",
    .settled_by = "",
    .reverses = "",
    .pair = "",
    .rate = 0,
    .source = "",
    .chain = example_transfer,
    .about = "",
    .detail = "",
    .author = "loyalty",
    .expires_at = null,
    .happened_at = 1_790_000_000_000,
    .posted_at = 1_790_000_000_000,
    .debit_after = 500,
    .credit_after = 500,
};

/// Accounts read while showing transfers, each once.
const Known = struct {
    rows: std.StringHashMapUnmanaged(AccountRow) = .empty,

    fn of(known: *Known, ctx: *Ctx, id: []const u8) Error!AccountRow {
        std.debug.assert(id.len > 0);

        if (known.rows.get(id)) |row| {
            return row;
        }

        const found = try store.ledger_accounts.get(ctx.db, ctx.arena, id);
        const row = found orelse return error.NotFound;

        try known.rows.put(ctx.arena, row.id, row);

        return row;
    }
};

fn shown_of(ctx: *Ctx, known: *Known, row: TransferRow) Error!Shown {
    std.debug.assert(row.id.len > 0);

    const debit = try known.of(ctx, row.debit);
    const credit = try known.of(ctx, row.credit);
    const action = std.meta.stringToEnum(model.Action, row.action) orelse .transfer;
    var settled_by: []const u8 = "";
    const status: model.Status = switch (action) {
        .hold => status: {
            const settled = try store.ledger_transfers.settle_of(ctx.db, ctx.arena, row.id);
            const found = settled orelse break :status .pending;

            settled_by = found.id;

            break :status if (std.mem.eql(u8, found.action, "post"))
                .posted
            else if (std.mem.eql(u8, found.action, "expire")) .expired else .voided;
        },
        .void => .voided,
        .expire => .expired,
        else => .posted,
    };
    const pair = if (row.pair.len > 0) row.pair else try pair_of(ctx, row);

    return .{
        .transfer = row.id,
        .maker = row.maker,
        .maker_id = row.maker_id,
        .made_for = row.made_for,
        .action = row.action,
        .status = status,
        .debit = row.debit,
        .debit_owner = debit.owner,
        .debit_name = debit.name,
        .credit = row.credit,
        .credit_owner = credit.owner,
        .credit_name = credit.name,
        .unit = row.unit,
        .amount = row.amount,
        .reason = row.reason,
        .reason_label = declared.reason_label(ctx, row.maker, row.reason),
        .hold = row.hold,
        .settled_by = settled_by,
        .reverses = row.reverses,
        .pair = pair,
        .rate = row.rate,
        .source = row.source,
        .chain = row.chain,
        .about = row.about,
        .detail = row.detail,
        .author = row.author,
        .expires_at = row.expires_at,
        .happened_at = row.happened_at,
        .posted_at = row.posted_at,
        .debit_after = row.debit_after,
        .credit_after = row.credit_after,
    };
}

/// A conversion's first leg finds its second by the maker's id.
fn pair_of(ctx: *Ctx, row: TransferRow) Error![]const u8 {
    std.debug.assert(row.id.len > 0);

    if (!std.mem.eql(u8, row.action, "convert") or row.leg != 0) {
        return "";
    }

    const maker = row.maker;
    const second = try store.ledger_transfers.by_maker(ctx.db, ctx.arena, maker, row.maker_id, 1);

    return if (second) |found| found.id else "";
}

pub const Side = enum { debit, credit };

/// One transfer as an account's history shows it.
pub const Line = struct {
    transfer: []const u8,
    action: []const u8,
    status: model.Status,
    reason: []const u8,
    reason_label: []const u8,
    maker: []const u8,
    other: []const u8,
    other_owner: []const u8,
    other_name: []const u8,
    side: Side,
    /// On this account's side: positive when it grows the balance.
    amount: i64,
    balance_after: i64,
    about: []const u8,
    detail: []const u8,
    author: []const u8,
    happened_at: i64,
    posted_at: i64,
};

pub const History = struct {
    pub const name = "ledger.history";
    /// Plugin code calls it for whoever the request is for, visitors too, held to the
    /// plugin's own reach.
    pub const plugins_only = true;
    pub const description = "An account's transfers, newest first";
    pub const details =
        \\A page of the account's transfers, newest first: each with its side, its amount on
        \\this account (positive when it grows the balance), the balance after it and its
        \\status. The next page starts `before` the last one shown.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        account: []const u8,
        about: []const u8 = "",
        from: ?i64 = null,
        to: ?i64 = null,
        before: []const u8 = "",
        limit: u32 = 50,
    };
    pub const Out = struct {
        lines: []const Line,
        /// Where the next page starts; empty after the last.
        before: []const u8,
    };
    pub const example: In = .{
        .account = example_account,
    };
    pub const example_out: Out = .{
        .lines = &.{},
        .before = "",
    };
    pub const field_docs: Docs(In) = .{
        .account = "The account",
        .about = "Only transfers about this record",
        .from = "From this time (ms)",
        .to = "Before this time (ms)",
        .before = "Transfers before this one: the next page",
        .limit = "1 to 200",
    };
    pub const output_docs: Docs(Out) = .{
        .lines = "Newest first",
        .before = "The next page's `before`; empty after the last",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        const row = try readable(ctx, in.account);

        if (in.limit == 0 or in.limit > store.ledger_transfers.page_max) {
            return error.Invalid;
        }

        const rows = try store.ledger_transfers.history(ctx.db, ctx.arena, row.id, .{
            .about = in.about,
            .from_ms = in.from,
            .to_ms = in.to,
            .before = in.before,
        }, in.limit);
        const lines = try ctx.arena.alloc(Line, rows.len);
        var known: Known = .{};

        for (rows, lines) |transfer, *line| {
            line.* = try line_of(ctx, &known, row, transfer);
        }

        std.debug.assert(lines.len <= in.limit);

        return .{
            .lines = lines,
            .before = if (rows.len == in.limit) rows[rows.len - 1].id else "",
        };
    }
};

fn line_of(ctx: *Ctx, known: *Known, account: AccountRow, row: TransferRow) Error!Line {
    std.debug.assert(row.id.len > 0);

    const shown = try shown_of(ctx, known, row);
    const on_debit = std.mem.eql(u8, row.debit, account.id);
    const grows = on_debit == kind_of(account).grows_by_debit();

    return .{
        .transfer = row.id,
        .action = row.action,
        .status = shown.status,
        .reason = row.reason,
        .reason_label = shown.reason_label,
        .maker = row.maker,
        .other = if (on_debit) row.credit else row.debit,
        .other_owner = if (on_debit) shown.credit_owner else shown.debit_owner,
        .other_name = if (on_debit) shown.credit_name else shown.debit_name,
        .side = if (on_debit) .debit else .credit,
        .amount = if (grows) row.amount else -row.amount,
        .balance_after = if (on_debit) row.debit_after else row.credit_after,
        .about = row.about,
        .detail = row.detail,
        .author = row.author,
        .happened_at = row.happened_at,
        .posted_at = row.posted_at,
    };
}

pub const Find = struct {
    pub const name = "ledger.find";
    /// Plugin code calls it for whoever the request is for, visitors too, held to the
    /// plugin's own reach.
    pub const plugins_only = true;
    pub const description = "Transfers about a record, on an account or of a reason";
    pub const details =
        \\A page of the transfers on accounts the caller may read that match every filter
        \\given: about a record, about a finer one (`detail`), on one account, on the
        \\accounts of one name, of one reason. At least one of `about`, `detail`, `account`
        \\and `name`; each is read through an index. Oldest first, or `newest` first; a page
        \\is 50 unless `limit` says, 200 at most, and the next starts `after` the last.
        \\For sums, ask `ledger.totals`: it adds up in the database and reads no transfer.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        about: []const u8 = "",
        detail: []const u8 = "",
        reason: []const u8 = "",
        account: []const u8 = "",
        /// The caller's accounts of this name; with `plugin`, another's it may read.
        name: []const u8 = "",
        plugin: []const u8 = "",
        after: []const u8 = "",
        limit: u32 = 50,
        newest: bool = false,
    };
    pub const Out = struct {
        transfers: []const Shown,
        next: []const u8,
    };
    pub const example: In = .{
        .about = "0190c8a3d2e3000031d4e5f6",
    };
    pub const example_out: Out = .{
        .transfers = &.{example_shown},
        .next = "",
    };
    pub const field_docs: Docs(In) = .{
        .about = "The record they are about",
        .detail = "The finer record they are about",
        .reason = "Only transfers of this reason",
        .account = "Only transfers on this account, either side",
        .name = "Only transfers on the accounts of this name",
        .plugin = "Whose accounts the name is; the caller's own when left out",
        .after = "Transfers past this one: the next page",
        .limit = "1 to 200; 50 when left out",
        .newest = "Newest first; oldest first when left out",
    };
    pub const output_docs: Docs(Out) = .{
        .transfers = "In the order asked",
        .next = "The next page's `after`; empty after the last",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        const narrowed = in.about.len > 0 or in.detail.len > 0 or in.account.len > 0 or
            in.name.len > 0;

        if (!narrowed or in.limit == 0 or in.limit > sdk.operation.page_limit_max) {
            return error.Invalid;
        }

        const rows = try store.ledger_transfers.search(ctx.db, ctx.arena, .{
            .about = in.about,
            .detail = in.detail,
            .reason = in.reason,
            .account = in.account,
            .owner = try owner_named(ctx, in.account, in.name, in.plugin),
            .name = in.name,
            .past = in.after,
            .newest = in.newest,
        }, in.limit);
        var shown: std.ArrayList(Shown) = .empty;
        var known: Known = .{};

        for (rows) |row| {
            const debit = try known.of(ctx, row.debit);
            const credit = try known.of(ctx, row.credit);

            if (may_read(ctx, debit.owner) or may_read(ctx, credit.owner)) {
                try shown.append(ctx.arena, try shown_of(ctx, &known, row));
            }
        }

        std.debug.assert(shown.items.len <= rows.len);

        return .{
            .transfers = shown.items,
            .next = if (rows.len == in.limit) rows[rows.len - 1].id else "",
        };
    }
};

/// Whose accounts a read by `name` takes, checked: the plugin named, else the caller's own;
/// and an `account` given is one the caller may read. Refused for anyone it may not read.
fn owner_named(
    ctx: *Ctx,
    account: []const u8,
    name: []const u8,
    plugin: []const u8,
) Error![]const u8 {
    std.debug.assert(name.len <= 128);

    if (account.len > 0) {
        _ = try readable(ctx, account);
    }

    const owner = if (plugin.len > 0) plugin else ctx.plugin;

    if (name.len > 0 and (owner.len == 0 or !may_read(ctx, owner))) {
        return error.Denied;
    }

    return owner;
}

pub const Sum = struct {
    reason: []const u8,
    reason_label: []const u8,
    unit: []const u8,
    /// The finer record the sum is of, when sums were asked for `details`; empty otherwise.
    detail: []const u8 = "",
    debits_posted: i64,
    credits_posted: i64,
    debits_pending: i64,
    credits_pending: i64,
};

pub const Totals = struct {
    pub const name = "ledger.totals";
    /// Plugin code calls it for whoever the request is for, visitors too, held to the
    /// plugin's own reach.
    pub const plugins_only = true;
    pub const description = "Debits and credits per reason over matching transfers";
    pub const details =
        \\Posted and open-hold amounts per reason and unit over the transfers that match:
        \\about a record, on one account, or on the caller's accounts of one name, between
        \\two times, of one reason, about a finer record (`detail`). On an account (or a
        \\name) each amount is on its debit or credit side; about a record alone, each
        \\transfer counts once on both. With `details` (up to 200 finer records: a page of
        \\an order's charges) there is one sum per detail, reason and unit, so a page's
        \\figures are one read. Added up in the database: no transfer is read. A page of 200
        \\sums at a time, by detail, reason and unit: `next` continues it.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        about: []const u8 = "",
        detail: []const u8 = "",
        details: []const []const u8 = &.{},
        reason: []const u8 = "",
        account: []const u8 = "",
        /// The caller's accounts of this name; with `plugin`, another's it may read.
        name: []const u8 = "",
        plugin: []const u8 = "",
        from: ?i64 = null,
        to: ?i64 = null,
        after: []const u8 = "",
    };
    pub const Out = struct {
        totals: []const Sum,
        next: []const u8 = "",
    };
    pub const example: In = .{
        .about = "0190c8a3d2e3000031d4e5f6",
    };
    pub const example_out: Out = .{
        .totals = &.{},
    };
    pub const field_docs: Docs(In) = .{
        .about = "The record they are about",
        .detail = "The finer record they are about",
        .details = "Finer records, up to 200: one sum per detail, reason and unit",
        .reason = "Only transfers of this reason",
        .account = "One account",
        .name = "An account name",
        .plugin = "Whose accounts the name is; the caller's own when left out",
        .from = "From this time (ms)",
        .to = "Before this time (ms)",
        .after = "The page after this sum: the `next` the last page answered",
    };
    pub const output_docs: Docs(Out) = .{
        .totals = "One per reason and unit; per detail too when `details` were named",
        .next = "The next page's `after`; empty after the last",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const narrowed = in.about.len > 0 or in.detail.len > 0 or in.details.len > 0 or
            in.account.len > 0 or in.name.len > 0;

        if (!narrowed or in.details.len > store.ledger_transfers.details_max) {
            return error.Invalid;
        }

        const owner = try owner_named(ctx, in.account, in.name, in.plugin);
        const limit = sdk.operation.page_limit_max;
        const sums = try store.ledger_transfers.sums(ctx.db, ctx.arena, .{
            .about = in.about,
            .detail = in.detail,
            .details = in.details,
            .reason = in.reason,
            .account = in.account,
            .owner = owner,
            .name = in.name,
            .from_ms = in.from,
            .to_ms = in.to,
            .after = try sum_key_of(in.after),
            .limit = limit,
        });

        std.debug.assert(sums.len <= limit);

        const totals = try ctx.arena.alloc(Sum, sums.len);

        for (sums, totals) |sum, *total| {
            total.* = .{
                .reason = sum.reason,
                .reason_label = sum.reason,
                .unit = sum.unit,
                .detail = sum.detail,
                .debits_posted = sum.debits_posted,
                .credits_posted = sum.credits_posted,
                .debits_pending = sum.debits_pending,
                .credits_pending = sum.credits_pending,
            };
        }

        const last = if (sums.len == limit) sums[sums.len - 1] else null;

        return .{
            .totals = totals,
            .next = if (last) |sum| std.fmt.allocPrint(ctx.arena, "{s}/{s}/{s}", .{
                sum.detail,
                sum.reason,
                sum.unit,
            }) catch return error.OutOfMemory else "",
        };
    }
};

/// `<detail>/<reason>/<unit>`, as `Totals` answers it in `next`; null for the first page.
fn sum_key_of(after: []const u8) Error!?store.ledger_transfers.SumKey {
    if (after.len == 0) {
        return null;
    }

    if (after.len > 512) {
        return error.Invalid;
    }

    std.debug.assert(after.len > 0 and after.len <= 512);

    var parts = std.mem.splitScalar(u8, after, '/');
    const detail = parts.next() orelse return error.Invalid;
    const reason = parts.next() orelse return error.Invalid;
    const unit = parts.next() orelse return error.Invalid;

    if (parts.next() != null) {
        return error.Invalid;
    }

    return .{
        .detail = detail,
        .reason = reason,
        .unit = unit,
    };
}

pub const Get = struct {
    pub const name = "ledger.get";
    /// Plugin code calls it for whoever the request is for, visitors too, held to the
    /// plugin's own reach.
    pub const plugins_only = true;
    pub const description = "One transfer";
    pub const details =
        \\A transfer by core's id (`transfer`), or by the calling plugin's own id (`id`):
        \\everything it holds, with what settled it, the hold it settles, its conversion's
        \\other leg.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        transfer: []const u8 = "",
        id: []const u8 = "",
    };
    pub const Out = Shown;
    pub const example: In = .{
        .transfer = example_transfer,
    };
    pub const example_out: Out = example_shown;
    pub const field_docs: Docs(In) = .{
        .transfer = "The transfer, by core's id",
        .id = "The transfer, by the calling plugin's own id",
    };
    pub const output_docs: Docs(Out) = .{
        .transfer = "Core's id",
        .maker = "The plugin that made it",
        .maker_id = "Its maker's id for it; empty for a post, void or expiry",
        .made_for = "The plugin whose account it moved by being handed it; empty if none",
        .action = "transfer, hold, post, void, expire, reverse or convert",
        .status = "posted, pending, voided or expired",
        .debit = "The account debited",
        .debit_owner = "Its owner",
        .debit_name = "Its name",
        .credit = "The account credited",
        .credit_owner = "Its owner",
        .credit_name = "Its name",
        .unit = "What it counts",
        .amount = "In the unit's smallest step",
        .reason = "Its maker's reason",
        .reason_label = "The reason in words",
        .hold = "The hold it settles",
        .settled_by = "What settled this hold",
        .reverses = "The transfer it undoes",
        .reversals = "Its reversals, oldest first; the first 200",
        .pair = "A conversion's other leg",
        .rate = "A conversion's rate, in millionths",
        .source = "Where the rate came from",
        .chain = "The first transfer of the chain it was posted in",
        .about = "What it belongs to",
        .detail = "A finer record",
        .author = "A person's id, else the plugin, job or visitor",
        .expires_at = "A hold's expiry",
        .happened_at = "When it happened in the world",
        .posted_at = "When the ledger took it",
        .debit_after = "The debit account's posted balance after it",
        .credit_after = "The credit account's posted balance after it",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        const found = if (in.transfer.len > 0)
            try store.ledger_transfers.get(ctx.db, ctx.arena, in.transfer)
        else if (in.id.len > 0 and ctx.plugin.len > 0)
            try store.ledger_transfers.by_maker(ctx.db, ctx.arena, ctx.plugin, in.id, 0)
        else
            return error.Invalid;
        const row = found orelse return error.NotFound;
        var known: Known = .{};

        std.debug.assert(row.id.len > 0);

        const debit = try known.of(ctx, row.debit);
        const credit = try known.of(ctx, row.credit);

        if (!may_read(ctx, debit.owner) and !may_read(ctx, credit.owner)) {
            return error.NotFound;
        }

        var shown = try shown_of(ctx, &known, row);
        const reversals = try store.ledger_transfers.reversals_of(ctx.db, ctx.arena, row.id);
        const ids = try ctx.arena.alloc([]const u8, reversals.len);

        for (reversals, ids) |reversal, *id| {
            id.* = reversal.id;
        }

        shown.reversals = ids;

        return shown;
    }
};

pub const AccountView = @import("accounts.zig").AccountView;
pub const Accounts = @import("accounts.zig").Accounts;
pub const Account = @import("accounts.zig").Account;
pub const Check = @import("accounts.zig").Check;
