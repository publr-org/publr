const std = @import("std");
const sdk = @import("../../sdk.zig");
const public = @import("../../publr/operations/ledger/reads.zig");
const shown_shapes = @import("../../publr/operations/ledger/shown.zig");
const store = @import("../../store.zig");
const model = @import("../../model/ledger.zig");
const registry = @import("../../server/registry.zig");
const declared = @import("declared.zig");
const permission = @import("../../model/permission.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const AccountRow = store.ledger_accounts.Row;
const TransferRow = store.ledger_transfers.Row;

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
    pub const shape = public.Balance;
    pub const name = shape.name;
    pub const plugins_only = shape.plugins_only;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

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

pub const Shown = shown_shapes.Shown;

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

pub const Side = shown_shapes.Side;
pub const Line = shown_shapes.Line;

pub const History = struct {
    pub const shape = public.History;
    pub const name = shape.name;
    pub const plugins_only = shape.plugins_only;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

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
    pub const shape = public.Find;
    pub const name = shape.name;
    pub const plugins_only = shape.plugins_only;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

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

pub const Sum = shown_shapes.Sum;

pub const Totals = struct {
    pub const shape = public.Totals;
    pub const name = shape.name;
    pub const plugins_only = shape.plugins_only;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

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
    pub const shape = public.Get;
    pub const name = shape.name;
    pub const plugins_only = shape.plugins_only;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

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
