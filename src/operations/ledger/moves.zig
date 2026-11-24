//! Transfers and holds, reversals and conversions: each a row and two accounts' totals, the
//! limits checked against the totals as they stand in the chain.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const model = @import("../../model/ledger.zig");
const shapes = @import("../ledger.zig");
const engine = @import("engine.zig");
const declared = @import("declared.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const Book = engine.Book;
const Maker = engine.Maker;
const TransferRow = store.ledger_transfers.Row;
const refusals = model.refusals;
const refuse = engine.refuse;

/// What every transfer row starts from: the parts a step sets are filled in after.
fn blank(maker: Maker) TransferRow {
    std.debug.assert(maker.plugin.len > 0);

    return .{
        .id = "",
        .maker = maker.plugin,
        .maker_id = "",
        .leg = 0,
        .made_for = "",
        .action = "transfer",
        .debit = "",
        .credit = "",
        .unit = "",
        .amount = 0,
        .reason = "",
        .hold = "",
        .reverses = "",
        .pair = "",
        .rate = 0,
        .source = "",
        .chain = "",
        .about = "",
        .detail = "",
        .author = maker.author,
        .expires_at = null,
        .happened_at = 0,
        .posted_at = 0,
        .debit_after = 0,
        .credit_after = 0,
    };
}

fn check_id(ctx: *Ctx, id: []const u8) Error!void {
    std.debug.assert(model.id_len_max > 0);

    if (id.len == 0 or id.len > model.id_len_max) {
        return ctx.refuse(&.{.{
            .field = "id",
            .message = "The plugin's own id for it: 1 to 128 characters",
        }});
    }
}

fn check_references(ctx: *Ctx, about: []const u8, detail: []const u8) Error!void {
    std.debug.assert(ctx.now_ms >= 0);

    if (about.len > model.id_len_max or detail.len > model.id_len_max) {
        return error.Invalid;
    }
}

/// A transfer or a hold, as a chain's step.
pub fn move(
    ctx: *Ctx,
    maker: Maker,
    book: *Book,
    step: shapes.Step,
    chain: []const u8,
) Error!shapes.Done {
    std.debug.assert(step.action == .transfer or step.action == .hold);

    try check_id(ctx, step.id);
    try check_references(ctx, step.about, step.detail);

    if (step.amount <= 0) {
        return refuse(ctx, refusals.unbalanced);
    }

    try declared.check_reason(ctx, maker.plugin, step.reason);

    const action = if (step.action == .hold) "hold" else "transfer";

    if (try store.ledger_transfers.by_maker(ctx.db, ctx.arena, maker.plugin, step.id, 0)) |held| {
        return repeated(ctx, held, step, action);
    }

    var row = blank(maker);

    row.maker_id = step.id;
    row.action = action;
    row.reason = step.reason;
    row.chain = chain;
    row.about = step.about;
    row.detail = step.detail;
    row.expires_at = if (step.action == .hold) step.expires_at else null;
    row.happened_at = step.happened_at orelse ctx.now_ms;

    const done = try moved(ctx, maker, book, .{
        .row = row,
        .debit = step.debit,
        .credit = step.credit,
        .amount = step.amount,
        .up_to = step.up_to,
        .pending = step.action == .hold,
    });

    if (step.action == .hold and done.made) {
        if (step.expires_at) |at| {
            try engine.scheduled(ctx, done.transfer, at);
        }
    }

    return done;
}

/// The same id again: the transfer made then when every part is the same, else refused.
fn repeated(
    ctx: *Ctx,
    held: TransferRow,
    step: shapes.Step,
    action: []const u8,
) Error!shapes.Done {
    std.debug.assert(held.id.len > 0);

    const amount_same = if (step.up_to) held.amount <= step.amount else held.amount == step.amount;
    const happened_same = step.happened_at == null or step.happened_at.? == held.happened_at;
    const same = std.mem.eql(u8, held.action, action) and amount_same and happened_same and
        std.mem.eql(u8, held.debit, step.debit) and std.mem.eql(u8, held.credit, step.credit) and
        std.mem.eql(u8, held.reason, step.reason) and std.mem.eql(u8, held.about, step.about) and
        std.mem.eql(u8, held.detail, step.detail);

    if (!same) {
        return refuse(ctx, refusals.taken);
    }

    return .{
        .transfer = held.id,
        .amount = held.amount,
        .made = false,
    };
}

pub const Moving = struct {
    row: TransferRow,
    debit: []const u8,
    credit: []const u8,
    amount: i64,
    up_to: bool = false,
    pending: bool = false,
    /// Accounts already reached (a reversal's, the original's): no ownership check.
    reached: bool = false,
};

/// Checks the accounts and the limits, changes the totals and writes the row.
pub fn moved(ctx: *Ctx, maker: Maker, book: *Book, moving: Moving) Error!shapes.Done {
    std.debug.assert(moving.amount > 0);

    if (std.mem.eql(u8, moving.debit, moving.credit)) {
        return refuse(ctx, refusals.unbalanced);
    }

    const debit = try book.get(ctx, moving.debit);
    const credit = try book.get(ctx, moving.credit);
    var row = moving.row;

    if (!moving.reached) {
        const for_debit = try engine.reach(ctx, maker, debit);
        const for_credit = try engine.reach(ctx, maker, credit);

        row.made_for = if (for_debit.len > 0) for_debit else for_credit;
    }

    if (debit.row.closed or credit.row.closed) {
        return refuse(ctx, refusals.closed);
    }

    if (!std.mem.eql(u8, debit.row.unit, credit.row.unit)) {
        return refuse(ctx, refusals.unit_mismatch);
    }

    const amount = try allowed(ctx, debit, credit, moving.amount, moving.up_to);

    if (amount == 0) {
        return .{
            .transfer = "",
            .amount = 0,
            .made = false,
        };
    }

    try apply(ctx, debit, credit, amount, if (moving.pending) .pending else .posted);
    row.debit = debit.row.id;
    row.credit = credit.row.id;
    row.unit = debit.row.unit;
    row.amount = amount;

    return .{
        .transfer = try engine.write_row(ctx, row, debit, credit),
        .amount = amount,
        .made = true,
    };
}

/// What may move: all of it, or with `up_to` as much as the limits allow.
fn allowed(
    ctx: *Ctx,
    debit: *const Book.Entry,
    credit: *const Book.Entry,
    amount: i64,
    up_to: bool,
) Error!i64 {
    std.debug.assert(amount > 0);
    std.debug.assert(debit != credit);

    const debit_room = model.headroom(debit.kind, debit.limit, debit.totals, .debit);
    const credit_room = model.headroom(credit.kind, credit.limit, credit.totals, .credit);
    var room: ?i64 = debit_room;

    if (credit_room) |credited| {
        room = if (room) |debited| @min(debited, credited) else credited;
    }

    const limit = room orelse return amount;

    if (amount <= limit) {
        return amount;
    }

    if (up_to) {
        return limit;
    }

    return refuse(ctx, refusals.overdrawn);
}

pub const Totals = enum { posted, pending };

/// Adds the amount to the debit and credit totals of one kind; refused past 64 bits.
pub fn apply(
    ctx: *Ctx,
    debit: *Book.Entry,
    credit: *Book.Entry,
    amount: i64,
    totals: Totals,
) Error!void {
    std.debug.assert(amount > 0);
    std.debug.assert(debit != credit);

    const debit_total = if (totals == .posted)
        &debit.totals.debits_posted
    else
        &debit.totals.debits_pending;
    const credit_total = if (totals == .posted)
        &credit.totals.credits_posted
    else
        &credit.totals.credits_pending;
    const debited = model.added(debit_total.*, amount) orelse {
        return refuse(ctx, refusals.too_large);
    };
    const credited = model.added(credit_total.*, amount) orelse {
        return refuse(ctx, refusals.too_large);
    };

    debit_total.* = debited;
    credit_total.* = credited;
    debit.changed = true;
    credit.changed = true;
}

/// Undoes all or part of a posted transfer: its maker's, or made for the plugin reversing.
pub fn reverse(ctx: *Ctx, maker: Maker, book: *Book, in: shapes.Reverse.In) Error!shapes.Done {
    std.debug.assert(maker.plugin.len > 0);

    try check_id(ctx, in.id);
    try declared.check_reason(ctx, maker.plugin, in.reason);

    if (in.amount < 0 or in.transfer.len == 0 or in.transfer.len > model.id_len_max) {
        return error.Invalid;
    }

    if (try store.ledger_transfers.by_maker(ctx.db, ctx.arena, maker.plugin, in.id, 0)) |held| {
        const same = std.mem.eql(u8, held.reverses, in.transfer) and
            (in.amount == 0 or in.amount == held.amount);

        if (!same) {
            return refuse(ctx, refusals.taken);
        }

        return .{
            .transfer = held.id,
            .amount = held.amount,
            .made = false,
        };
    }

    const original = try store.ledger_transfers.get(ctx.db, ctx.arena, in.transfer) orelse {
        return error.NotFound;
    };
    const posts = std.meta.stringToEnum(model.Action, original.action) orelse .hold;
    const theirs = std.mem.eql(u8, original.maker, maker.plugin) or
        std.mem.eql(u8, original.made_for, maker.plugin);

    if (!theirs) {
        return refuse(ctx, refusals.not_yours);
    }

    if (!posts.posts()) {
        return refuse(ctx, refusals.over_reversed);
    }

    const left = original.amount - try store.ledger_transfers.reversed(ctx.db, original.id);
    const amount = if (in.amount == 0) left else in.amount;

    if (left <= 0 or amount > left) {
        return refuse(ctx, refusals.over_reversed);
    }

    var row = blank(maker);

    row.maker_id = in.id;
    row.action = "reverse";
    row.reason = in.reason;
    row.reverses = original.id;
    row.made_for = original.made_for;
    row.about = original.about;
    row.detail = original.detail;
    row.happened_at = ctx.now_ms;

    return moved(ctx, maker, book, .{
        .row = row,
        .debit = original.credit,
        .credit = original.debit,
        .amount = amount,
        .reached = true,
    });
}

/// Two legs in one chain, the second at the rate, rounded down to the target unit's step.
pub fn convert(
    ctx: *Ctx,
    maker: Maker,
    book: *Book,
    in: shapes.Convert.In,
) Error!shapes.Convert.Out {
    try check_id(ctx, in.id);
    try check_references(ctx, in.about, in.detail);
    try declared.check_reason(ctx, maker.plugin, in.reason);

    if (in.amount <= 0 or in.rate <= 0) {
        return refuse(ctx, refusals.unbalanced);
    }

    if (in.source.len > model.id_len_max) {
        return error.Invalid;
    }

    if (try store.ledger_transfers.by_maker(ctx.db, ctx.arena, maker.plugin, in.id, 0)) |held| {
        return converted_before(ctx, maker, held, in);
    }

    const from_debit = try book.get(ctx, in.from_debit);
    const to_debit = try book.get(ctx, in.to_debit);
    const from_scale = try declared.scale_of(ctx, from_debit.row.unit);
    const to_scale = try declared.scale_of(ctx, to_debit.row.unit);
    const to_amount = model.converted(in.amount, in.rate, from_scale, to_scale) orelse {
        return refuse(ctx, refusals.too_large);
    };

    if (to_amount <= 0) {
        return refuse(ctx, refusals.unbalanced);
    }

    var row = blank(maker);

    row.maker_id = in.id;
    row.action = "convert";
    row.reason = in.reason;
    row.rate = in.rate;
    row.source = in.source;
    row.about = in.about;
    row.detail = in.detail;
    row.happened_at = ctx.now_ms;

    const from = try moved(ctx, maker, book, .{
        .row = row,
        .debit = in.from_debit,
        .credit = in.from_credit,
        .amount = in.amount,
    });

    row.leg = 1;
    row.pair = from.transfer;
    row.chain = from.transfer;

    const to = try moved(ctx, maker, book, .{
        .row = row,
        .debit = in.to_debit,
        .credit = in.to_credit,
        .amount = to_amount,
    });

    return .{
        .from = from,
        .to = to,
    };
}

fn converted_before(
    ctx: *Ctx,
    maker: Maker,
    held: TransferRow,
    in: shapes.Convert.In,
) Error!shapes.Convert.Out {
    std.debug.assert(held.id.len > 0);

    const other = try store.ledger_transfers.by_maker(ctx.db, ctx.arena, maker.plugin, in.id, 1);
    const second = other orelse return refuse(ctx, refusals.taken);
    const same = held.amount == in.amount and held.rate == in.rate and
        std.mem.eql(u8, held.debit, in.from_debit) and
        std.mem.eql(u8, held.credit, in.from_credit) and
        std.mem.eql(u8, second.debit, in.to_debit) and std.mem.eql(u8, second.credit, in.to_credit);

    if (!same) {
        return refuse(ctx, refusals.taken);
    }

    return .{
        .from = .{
            .transfer = held.id,
            .amount = held.amount,
            .made = false,
        },
        .to = .{
            .transfer = second.id,
            .amount = second.amount,
            .made = false,
        },
    };
}
