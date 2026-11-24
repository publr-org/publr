//! Settling a hold: posted for its amount or less, voided, or voided at its expiry. A hold
//! settles once; the hold's row is never changed, its settling row points at it.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const model = @import("../../model/ledger.zig");
const shapes = @import("../ledger.zig");
const engine = @import("engine.zig");
const moves = @import("moves.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const Book = engine.Book;
const Maker = engine.Maker;
const TransferRow = store.ledger_transfers.Row;
const refusals = model.refusals;
const refuse = engine.refuse;

/// A post or a void of one of the maker's holds (or one made for it).
pub fn settle(
    ctx: *Ctx,
    maker: Maker,
    book: *Book,
    step: shapes.Step,
    chain: []const u8,
) Error!shapes.Done {
    std.debug.assert(step.action == .post_hold or step.action == .void_hold);

    if (step.hold.len == 0 or step.hold.len > model.id_len_max or step.amount < 0) {
        return error.Invalid;
    }

    const held = try hold_of(ctx, maker, step.hold);
    const posting = step.action == .post_hold;

    if (try store.ledger_transfers.settle_of(ctx.db, ctx.arena, held.id)) |settled| {
        return settled_before(ctx, held, settled, posting, step.amount);
    }

    // Past its expiry a hold is gone, whether or not core's job got to it yet.
    if (held.expires_at) |at| {
        if (at <= ctx.now_ms) {
            return refuse(ctx, refusals.expired);
        }
    }

    if (!posting) {
        return release(ctx, book, held, .void, chain, maker.author);
    }

    const amount = if (step.amount == 0) held.amount else step.amount;

    if (amount > held.amount) {
        return refuse(ctx, refusals.over_hold);
    }

    const debit = try book.get(ctx, held.debit);
    const credit = try book.get(ctx, held.credit);

    if (debit.row.closed or credit.row.closed) {
        return refuse(ctx, refusals.closed);
    }

    unpend(debit, credit, held.amount);
    try moves.apply(ctx, debit, credit, amount, .posted);

    var row = settling(held, "post", chain, maker.author);

    row.amount = amount;

    return .{
        .transfer = try engine.write_row(ctx, row, debit, credit),
        .amount = amount,
        .made = true,
    };
}

/// The hold by its maker's id: the maker's own, else one the plugin that called it made.
fn hold_of(ctx: *Ctx, maker: Maker, id: []const u8) Error!TransferRow {
    std.debug.assert(id.len > 0);

    const own = try store.ledger_transfers.by_maker(ctx.db, ctx.arena, maker.plugin, id, 0);
    const found = own orelse if (maker.handed_by.len > 0)
        try store.ledger_transfers.by_maker(ctx.db, ctx.arena, maker.handed_by, id, 0)
    else
        null;
    const held = found orelse return refuse(ctx, refusals.no_hold);

    if (!std.mem.eql(u8, held.action, "hold")) {
        return refuse(ctx, refusals.no_hold);
    }

    return held;
}

fn settled_before(
    ctx: *Ctx,
    held: TransferRow,
    settled: TransferRow,
    posting: bool,
    amount: i64,
) Error!shapes.Done {
    std.debug.assert(std.mem.eql(u8, settled.hold, held.id));

    const action = std.meta.stringToEnum(model.Action, settled.action) orelse .void;

    if (action == .expire) {
        return refuse(ctx, refusals.expired);
    }

    const asked = if (amount == 0) held.amount else amount;
    const same = if (posting)
        action == .post and settled.amount == asked
    else
        action == .void;

    if (!same) {
        return refuse(ctx, refusals.settled);
    }

    return .{
        .transfer = settled.id,
        .amount = settled.amount,
        .made = false,
    };
}

fn unpend(debit: *Book.Entry, credit: *Book.Entry, amount: i64) void {
    std.debug.assert(debit.totals.debits_pending >= amount);
    std.debug.assert(credit.totals.credits_pending >= amount);

    debit.totals.debits_pending -= amount;
    credit.totals.credits_pending -= amount;
    debit.changed = true;
    credit.changed = true;
}

/// Releases a hold, as a void or at its expiry: the whole amount leaves the pending totals.
pub fn release(
    ctx: *Ctx,
    book: *Book,
    held: TransferRow,
    action: model.Action,
    chain: []const u8,
    author: []const u8,
) Error!shapes.Done {
    std.debug.assert(action == .void or action == .expire);
    std.debug.assert(held.amount > 0);

    const debit = try book.get(ctx, held.debit);
    const credit = try book.get(ctx, held.credit);

    unpend(debit, credit, held.amount);

    const row = settling(held, @tagName(action), chain, author);

    return .{
        .transfer = try engine.write_row(ctx, row, debit, credit),
        .amount = held.amount,
        .made = true,
    };
}

/// A settling row: the hold's accounts, reason and references, pointing at the hold.
fn settling(
    held: TransferRow,
    action: []const u8,
    chain: []const u8,
    author: []const u8,
) TransferRow {
    std.debug.assert(held.id.len > 0);
    std.debug.assert(action.len > 0);

    var row = held;

    row.id = "";
    row.maker_id = "";
    row.leg = 0;
    row.action = action;
    row.hold = held.id;
    row.chain = chain;
    row.author = author;
    row.expires_at = null;

    return row;
}
