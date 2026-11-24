//! The ledger's writes: opening accounts, posting chains of transfers and holds, settling
//! holds, reversals and conversions. A chain reads each account it touches once, checks every
//! step against the totals as they stand after the steps before it, writes one row per step
//! and each changed account once, all in the call's write: refused, it undoes only itself.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const model = @import("../../model/ledger.zig");
const shapes = @import("../ledger.zig");
const declared = @import("declared.zig");
const changes = @import("../project/changes.zig");
const moves = @import("moves.zig");
const holds = @import("holds.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const Row = store.ledger_accounts.Row;
const TransferRow = store.ledger_transfers.Row;
const refusals = model.refusals;

pub fn refuse(ctx: *Ctx, refusal: model.Refusal) error{Failed} {
    std.debug.assert(refusal.name.len > 0);
    std.debug.assert(refusal.status >= 400);

    return ctx.fail(.{
        .name = refusal.name,
        .status = refusal.status,
        .message = refusal.message,
    });
}

/// Who moves: the plugin whose code runs, the plugin that handed it accounts by calling it,
/// and who to name as the author.
pub const Maker = struct {
    plugin: []const u8,
    handed_by: []const u8,
    author: []const u8,
};

/// The plugin moving; refused for anyone but a plugin's code.
pub fn maker_of(ctx: *Ctx) Error!Maker {
    std.debug.assert(ctx.now_ms >= 0);

    if (ctx.plugin.len == 0 or std.mem.eql(u8, ctx.plugin, store.job_queue.core)) {
        return error.Denied;
    }

    const handed = !std.mem.eql(u8, ctx.handed_by, ctx.plugin);

    return .{
        .plugin = ctx.plugin,
        .handed_by = if (handed) ctx.handed_by else "",
        .author = author_of(ctx),
    };
}

/// A person's id, else the job running or the plugin, else `visitor`: as the activity log
/// names them.
pub fn author_of(ctx: *const Ctx) []const u8 {
    std.debug.assert(ctx.now_ms >= 0);

    if (ctx.caller.user_id()) |id| {
        return id;
    }

    if (ctx.job.len > 0) {
        return ctx.job;
    }

    return if (ctx.plugin.len > 0) ctx.plugin else "visitor";
}

pub fn open(ctx: *Ctx, in: shapes.Open.In) Error!shapes.Open.Out {
    const maker = try maker_of(ctx);
    const ledger = declared.of(ctx, maker.plugin) orelse return ctx.refuse(&.{.{
        .field = "name",
        .message = "The plugin declares no ledger (`publr.ledger.define`)",
    }});
    const account = ledger.account(in.name) orelse return ctx.refuse(&.{.{
        .field = "name",
        .message = "Not one of the plugin's declared account names",
    }});

    std.debug.assert(account.name.len > 0);

    if (in.key.len > 0 and (!model.word_like(in.key, false) or in.key.len > model.name_len_max)) {
        return ctx.refuse(&.{.{
            .field = "key",
            .message = "A key is a word of letters, digits and _",
        }});
    }

    if ((in.holder_kind == .none) != (in.holder.len == 0) or in.holder.len > model.id_len_max) {
        return error.Invalid;
    }

    _ = try declared.scale_of(ctx, in.unit);

    const identity: store.ledger_accounts.Identity = .{
        .owner = maker.plugin,
        .name = account.name,
        .holder_kind = if (in.holder_kind == .none) "" else @tagName(in.holder_kind),
        .holder = in.holder,
        .key = in.key,
        .unit = in.unit,
    };

    if (try store.ledger_accounts.find(ctx.db, ctx.arena, identity)) |held| {
        return .{
            .account = held.id,
            .opened = false,
        };
    }

    const id = try store.ledger_accounts.insert(ctx.db, ctx.io, ctx.arena, .{
        .identity = identity,
        .kind = @tagName(account.kind),
        .limit_kept = @tagName(account.limit),
        .now_ms = ctx.now_ms,
    });

    return .{
        .account = id,
        .opened = true,
    };
}

/// The accounts a chain touches, read once, changed in memory and written back once.
pub const Book = struct {
    entries: std.StringHashMapUnmanaged(*Entry) = .empty,
    order: std.ArrayList(*Entry) = .empty,

    pub const Entry = struct {
        row: Row,
        kind: model.Kind,
        limit: model.Limit,
        totals: model.Totals,
        changed: bool = false,
    };

    pub fn get(book: *Book, ctx: *Ctx, id: []const u8) Error!*Entry {
        std.debug.assert(book.order.items.len == book.entries.count());

        if (book.entries.get(id)) |found| {
            return found;
        }

        if (id.len == 0 or id.len > model.id_len_max) {
            return refuse(ctx, refusals.no_account);
        }

        const row = try store.ledger_accounts.get(ctx.db, ctx.arena, id) orelse {
            return refuse(ctx, refusals.no_account);
        };
        const entry = try ctx.arena.create(Entry);

        entry.* = .{
            .row = row,
            .kind = std.meta.stringToEnum(model.Kind, row.kind) orelse return error.Invalid,
            .limit = std.meta.stringToEnum(model.Limit, row.limit_kept) orelse .none,
            .totals = .{
                .debits_posted = row.debits_posted,
                .credits_posted = row.credits_posted,
                .debits_pending = row.debits_pending,
                .credits_pending = row.credits_pending,
            },
        };
        try book.entries.put(ctx.arena, row.id, entry);
        try book.order.append(ctx.arena, entry);

        return entry;
    }

    /// Writes each changed account's totals, and says they changed: pages that read them are
    /// built again.
    pub fn save(book: *Book, ctx: *Ctx) Error!void {
        std.debug.assert(book.order.items.len == book.entries.count());

        for (book.order.items) |entry| {
            if (!entry.changed) {
                continue;
            }

            const totals = entry.totals;

            try store.ledger_accounts.save_totals(ctx.db, entry.row.id, .{
                .debits_posted = totals.debits_posted,
                .credits_posted = totals.credits_posted,
                .debits_pending = totals.debits_pending,
                .credits_pending = totals.credits_pending,
            });
            changes.ledger_changed(ctx, entry.row.id) catch |err| {
                std.log.debug("ledger: not raised: {t}", .{err});
                ctx.dependency_failure = true;
            };
            entry.changed = false;
        }
    }
};

/// Whether `maker` may move the account: its own, or the plugin that called it handed it.
/// Answers the plugin it moves it for: empty for its own.
pub fn reach(ctx: *Ctx, maker: Maker, entry: *const Book.Entry) Error![]const u8 {
    std.debug.assert(maker.plugin.len > 0);

    if (std.mem.eql(u8, entry.row.owner, maker.plugin)) {
        return "";
    }

    if (maker.handed_by.len > 0 and std.mem.eql(u8, entry.row.owner, maker.handed_by)) {
        return maker.handed_by;
    }

    return refuse(ctx, refusals.not_yours);
}

/// Posts steps as one chain: all of them, or none when one is refused.
pub fn post(ctx: *Ctx, steps: []const shapes.Step) Error![]const shapes.Done {
    const maker = try maker_of(ctx);
    const done = try ctx.arena.alloc(shapes.Done, steps.len);
    var book: Book = .{};
    var chain: []const u8 = "";

    if (steps.len == 0) {
        return ctx.refuse(&.{.{
            .field = "steps",
            .message = "A chain takes at least one step",
        }});
    }

    for (steps, done) |step, *slot| {
        slot.* = switch (step.action) {
            .transfer, .hold => try moves.move(ctx, maker, &book, step, chain),
            .post_hold, .void_hold => try holds.settle(ctx, maker, &book, step, chain),
        };

        if (chain.len == 0 and slot.made) {
            chain = slot.transfer;
        }
    }

    try book.save(ctx);

    std.debug.assert(done.len == steps.len);

    return done;
}

pub fn reverse(ctx: *Ctx, in: shapes.Reverse.In) Error!shapes.Done {
    const maker = try maker_of(ctx);
    var book: Book = .{};
    const done = try moves.reverse(ctx, maker, &book, in);

    std.debug.assert(done.amount > 0);

    try book.save(ctx);

    return done;
}

pub fn convert(ctx: *Ctx, in: shapes.Convert.In) Error!shapes.Convert.Out {
    const maker = try maker_of(ctx);
    var book: Book = .{};
    const done = try moves.convert(ctx, maker, &book, in);

    std.debug.assert(done.from.amount > 0);

    try book.save(ctx);

    return done;
}

pub fn set_closed(ctx: *Ctx, account: []const u8, closed: bool) Error!void {
    const maker = try maker_of(ctx);
    var book: Book = .{};
    const entry = try book.get(ctx, account);

    std.debug.assert(entry.row.id.len > 0);

    if (!std.mem.eql(u8, entry.row.owner, maker.plugin)) {
        return refuse(ctx, refusals.not_yours);
    }

    try store.ledger_accounts.set_closed(ctx.db, account, closed);
}

/// A hold voided by its expiry, as its owner hears it.
pub const Expired = @import("../../sdk/plugin/hook_define.zig").event(.{
    .name = "ledger.expired",
    .payload = ExpiredPayload,
});

pub const ExpiredPayload = struct {
    /// The hold, by core's id.
    transfer: []const u8,
    /// Its maker's own id for it.
    hold: []const u8,
    maker: []const u8,
    debit: []const u8,
    credit: []const u8,
    unit: []const u8,
    amount: i64,
    reason: []const u8,
    about: []const u8,
    detail: []const u8,
};

pub const Expiring = struct {
    transfer: []const u8,
};

/// Core's queued job for a hold's expiry: voids it when nothing settled it first.
pub fn expire_job(ctx: *Ctx, in: Expiring) Error!void {
    std.debug.assert(ctx.job.len > 0);
    std.debug.assert(in.transfer.len > 0);

    const held = try store.ledger_transfers.get(ctx.db, ctx.arena, in.transfer) orelse return;

    if (try store.ledger_transfers.settle_of(ctx.db, ctx.arena, held.id) != null) {
        return;
    }

    var book: Book = .{};

    _ = try holds.release(ctx, &book, held, .expire, "", held.maker);
    try book.save(ctx);
    ctx.emit(Expired, .{
        .transfer = held.id,
        .hold = held.maker_id,
        .maker = held.maker,
        .debit = held.debit,
        .credit = held.credit,
        .unit = held.unit,
        .amount = held.amount,
        .reason = held.reason,
        .about = held.about,
        .detail = held.detail,
    });
}

/// The posted balance of an account as a transfer leaves it, for its row.
pub fn posted_of(entry: *const Book.Entry) i64 {
    std.debug.assert(entry.row.id.len > 0);

    return model.posted(entry.kind, entry.totals);
}

/// Writes a transfer's row with each account's balance after it.
pub fn write_row(
    ctx: *Ctx,
    row: TransferRow,
    debit: *const Book.Entry,
    credit: *const Book.Entry,
) Error![]const u8 {
    std.debug.assert(row.amount > 0);
    std.debug.assert(debit != credit);

    var written = row;

    written.debit_after = posted_of(debit);
    written.credit_after = posted_of(credit);
    written.posted_at = ctx.now_ms;

    return store.ledger_transfers.insert(ctx.db, ctx.io, ctx.arena, written);
}

pub fn scheduled(ctx: *Ctx, transfer: []const u8, expires_at: i64) Error!void {
    std.debug.assert(transfer.len > 0);

    const job = @import("../job.zig");

    try job.enqueue_at(ctx, "ledger_expire", Expiring{
        .transfer = transfer,
    }, @max(expires_at, ctx.now_ms));
}
