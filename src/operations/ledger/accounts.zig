//! Ledger accounts as people and plugins read them, and the full check that every account's
//! totals are what its transfers add up to and every unit's books balance.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const model = @import("../../model/ledger.zig");
const declared = @import("declared.zig");
const reads = @import("reads.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const Docs = sdk.operation.Docs;
const AccountRow = store.ledger_accounts.Row;

const example_account = "0190c8a3d2e1000014f2a6b9";

pub const AccountView = struct {
    account: []const u8,
    owner: []const u8,
    name: []const u8,
    label: []const u8,
    kind: model.Kind,
    limit: model.Limit,
    holder_kind: []const u8,
    holder: []const u8,
    key: []const u8,
    unit: []const u8,
    /// Decimal places of the unit's smallest step.
    scale: u8,
    posted: i64,
    pending: i64,
    available: i64,
    debits_posted: i64,
    credits_posted: i64,
    debits_pending: i64,
    credits_pending: i64,
    closed: bool,
    created_at: i64,
};

const example_view: AccountView = .{
    .account = example_account,
    .owner = "loyalty",
    .name = "held",
    .label = "Points held",
    .kind = .liability,
    .limit = .never_below_zero,
    .holder_kind = "person",
    .holder = "u_ada",
    .key = "",
    .unit = "loyalty.points",
    .scale = 0,
    .posted = 1200,
    .pending = -500,
    .available = 700,
    .debits_posted = 0,
    .credits_posted = 1200,
    .debits_pending = 500,
    .credits_pending = 0,
    .closed = false,
    .created_at = 1_790_000_000_000,
};

const view_docs: Docs(AccountView) = .{
    .account = "The account",
    .owner = "The plugin that opened it",
    .name = "Its declared name",
    .label = "Its name in words",
    .kind = "asset, liability, equity, income or expense",
    .limit = "none, never_below_zero or never_above_zero",
    .holder_kind = "record, person or empty",
    .holder = "Whose it is",
    .key = "Its key, for a name with many accounts tied to no record",
    .unit = "What it counts",
    .scale = "Decimal places of the unit's smallest step",
    .posted = "The posted balance",
    .pending = "Its holds, net",
    .available = "Once every hold posts",
    .debits_posted = "Debits posted",
    .credits_posted = "Credits posted",
    .debits_pending = "Debits pending",
    .credits_pending = "Credits pending",
    .closed = "Takes no transfer",
    .created_at = "When it was opened",
};

pub fn view_of(ctx: *Ctx, row: AccountRow) AccountView {
    std.debug.assert(row.id.len > 0);

    const kind = std.meta.stringToEnum(model.Kind, row.kind) orelse .asset;
    const totals: model.Totals = .{
        .debits_posted = row.debits_posted,
        .credits_posted = row.credits_posted,
        .debits_pending = row.debits_pending,
        .credits_pending = row.credits_pending,
    };
    const scale = declared.scale_of(ctx, row.unit) catch 0;

    return .{
        .account = row.id,
        .owner = row.owner,
        .name = row.name,
        .label = declared.account_label(ctx, row.owner, row.name),
        .kind = kind,
        .limit = std.meta.stringToEnum(model.Limit, row.limit_kept) orelse .none,
        .holder_kind = row.holder_kind,
        .holder = row.holder,
        .key = row.key,
        .unit = row.unit,
        .scale = scale,
        .posted = model.posted(kind, totals),
        .pending = model.pending(kind, totals),
        .available = model.available(kind, totals),
        .debits_posted = row.debits_posted,
        .credits_posted = row.credits_posted,
        .debits_pending = row.debits_pending,
        .credits_pending = row.credits_pending,
        .closed = row.closed,
        .created_at = row.created_at,
    };
}

pub const Accounts = struct {
    pub const name = "ledger.accounts";
    /// Plugin code calls it for whoever the request is for, visitors too, held to the
    /// plugin's own reach.
    pub const plugins_only = true;
    pub const description = "Ledger accounts, a page at a time";
    pub const details =
        \\Accounts the caller may read, in the order they were opened, narrowed by the plugin
        \\that owns them, their name, holder or unit. The next page starts `after` the last.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        plugin: []const u8 = "",
        name: []const u8 = "",
        holder: []const u8 = "",
        unit: []const u8 = "",
        after: []const u8 = "",
        limit: u32 = 50,
    };
    pub const Out = struct {
        accounts: []const AccountView,
        next: []const u8,
    };
    pub const example: In = .{
        .plugin = "loyalty",
    };
    pub const example_out: Out = .{
        .accounts = &.{example_view},
        .next = "",
    };
    pub const field_docs: Docs(In) = .{
        .plugin = "Only this plugin's",
        .name = "Only accounts of this name",
        .holder = "Only this holder's (a record's or a person's id)",
        .unit = "Only this unit (and per record of it)",
        .after = "Accounts after this one: the next page",
        .limit = "1 to 200",
    };
    pub const output_docs: Docs(Out) = .{
        .accounts = "In the order they were opened",
        .next = "The next page's `after`; empty after the last",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        if (in.limit == 0 or in.limit > store.ledger_accounts.page_max) {
            return error.Invalid;
        }

        const rows = try store.ledger_accounts.list(ctx.db, ctx.arena, .{
            .owner = in.plugin,
            .name = in.name,
            .holder = in.holder,
            .unit = in.unit,
            .owners = try readers_owners(ctx, in.plugin),
            .after = in.after,
        }, in.limit);
        const views = try ctx.arena.alloc(AccountView, rows.len);

        for (rows, views) |row, *view| {
            view.* = view_of(ctx, row);
        }

        std.debug.assert(views.len <= in.limit);

        return .{
            .accounts = views,
            .next = if (rows.len == in.limit) rows[rows.len - 1].id else "",
        };
    }
};

/// The owners a plugin's code may list: its own, the handed one, and those `ledger.read`
/// names; empty (every owner) for a person or core.
fn readers_owners(ctx: *Ctx, asked: []const u8) Error![]const []const u8 {
    std.debug.assert(ctx.now_ms >= 0);

    if (ctx.plugin.len == 0 or std.mem.eql(u8, ctx.plugin, store.job_queue.core)) {
        return &.{};
    }

    if (asked.len > 0) {
        if (!reads.may_read(ctx, asked)) {
            return error.Denied;
        }

        return &.{};
    }

    var owners: std.ArrayList([]const u8) = .empty;

    try owners.append(ctx.arena, ctx.plugin);

    if (ctx.handed_by.len > 0) {
        try owners.append(ctx.arena, ctx.handed_by);
    }

    const registry = @import("../../server/registry.zig");
    const access = switch (ctx.caller) {
        .plugin => |caller| caller.access,
        else => registry.SDK.compiled_access(ctx.plugin),
    };

    if (access) |found| {
        if (found.held_of("ledger.read")) |held| {
            try owners.appendSlice(ctx.arena, held.plugins);
        }
    }

    return owners.items;
}

pub const Account = struct {
    pub const name = "ledger.account";
    /// Plugin code calls it for whoever the request is for, visitors too, held to the
    /// plugin's own reach.
    pub const plugins_only = true;
    pub const description = "One ledger account";
    pub const details =
        \\The account's name, kind, holder, unit, limit, balances and its four totals.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        id: []const u8,
    };
    pub const Out = AccountView;
    pub const example: In = .{
        .id = example_account,
    };
    pub const example_out: Out = example_view;
    pub const field_docs: Docs(In) = .{
        .id = "The account",
    };
    pub const output_docs = view_docs;

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        const row = try reads.readable(ctx, in.id);

        std.debug.assert(row.id.len > 0);

        return view_of(ctx, row);
    }
};

pub const UnitLine = struct {
    unit: []const u8,
    debits_posted: i64,
    credits_posted: i64,
    /// Debits less credits, posted and pending: zero when the books balance.
    difference: i64,
    in_balance: bool,
};

pub const Differing = store.ledger_transfers.Differing;

pub const Check = struct {
    pub const name = "ledger.check";
    pub const description = "Check that the books balance";
    pub const details =
        \\Recomputes every account's totals from its transfers and each unit's sums, and
        \\answers what differs: nothing, unless there is a bug. Changes nothing.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        in_balance: bool,
        units: []const UnitLine,
        /// Accounts whose totals their transfers do not add up to.
        accounts: []const Differing,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .in_balance = true,
        .units = &.{},
        .accounts = &.{},
    };
    pub const field_docs: Docs(In) = .{};
    pub const output_docs: Docs(Out) = .{
        .in_balance = "Every unit balances and every account adds up",
        .units = "One line per unit",
        .accounts = "Accounts whose totals differ from their transfers, the first 200 by id; " ++
            "empty when none",
    };

    pub fn run(ctx: *Ctx, _: In, _: *const Grant) Error!Out {
        const units = try unit_lines(ctx);
        const accounts = try store.ledger_transfers.differing(ctx.db, ctx.arena);
        var balanced = accounts.len == 0;

        for (units) |line| {
            balanced = balanced and line.in_balance;
        }

        std.debug.assert(!balanced or accounts.len == 0);

        return .{
            .in_balance = balanced,
            .units = units,
            .accounts = accounts,
        };
    }
};

/// Each unit's debits and credits over every account: in balance when they are equal.
pub fn unit_lines(ctx: *Ctx) Error![]const UnitLine {
    std.debug.assert(ctx.now_ms >= 0);

    const sums = try store.ledger_accounts.unit_sums(ctx.db, ctx.arena);
    const lines = try ctx.arena.alloc(UnitLine, sums.len);

    for (sums, lines) |sum, *line| {
        const posted = sum.debits_posted - sum.credits_posted;
        const pending = sum.debits_pending - sum.credits_pending;

        line.* = .{
            .unit = sum.unit,
            .debits_posted = sum.debits_posted,
            .credits_posted = sum.credits_posted,
            .difference = posted + pending,
            .in_balance = posted == 0 and pending == 0,
        };
    }

    return lines;
}
