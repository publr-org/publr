const std = @import("std");
const sdk = @import("../../sdk.zig");
const public = @import("../../publr/operations/ledger/accounts.zig");
const store = @import("../../store.zig");
const model = @import("../../model/ledger.zig");
const declared = @import("declared.zig");
const reads = @import("reads.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const AccountRow = store.ledger_accounts.Row;

pub const AccountView = public.AccountView;

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
    pub const shape = public.Accounts;
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
    pub const shape = public.Account;
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
        const row = try reads.readable(ctx, in.id);

        std.debug.assert(row.id.len > 0);

        return view_of(ctx, row);
    }
};

pub const UnitLine = public.UnitLine;

pub const Differing = public.Differing;

pub const Check = struct {
    pub const shape = public.Check;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

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
