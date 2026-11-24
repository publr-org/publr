//! A kiosk paying `points` from its own cash: the ledger's handed-over accounts.
//!
//! `buy` hands its cash account to `points pay`, which may move it for that call; `raid`
//! moves points' own account itself and is refused; `peek` reads an account of points', which
//! its `ledger.read` grant names.
const std = @import("std");
const publr = @import("publr");

const manifest: publr.Manifest = .{
    .name = "kiosk",
    .version = "0.1.0",
};

/// Kiosk
pub const Ledger = publr.ledger.define(struct {
    /// Cash
    cash: publr.ledger.Asset(.{}),
    /// Sales
    sales: publr.ledger.Income(.{}),
}, .{
    .reasons = Reason,
});

pub const Reason = enum {
    /// Sold
    sold,
};

pub const PointsPay = publr.remote.operation("points.pay", struct {
    from: publr.ledger.Account,
    id: []const u8,
    /// Why: a ledger amount, in its unit's smallest step.
    amount: i64,
}, struct {
    transfer: []const u8,
    made_for: []const u8,
});

pub const BuyIn = struct {
    /// The kiosk's id for the sale
    id: []const u8,
    /// In grosze
    ///
    /// Why: a ledger amount, in its unit's smallest step.
    amount: i64,
};

pub const BuyOut = struct {
    /// The transfer points made
    transfer: []const u8,
    /// Whom it was made for
    made_for: []const u8,
    /// The kiosk's cash, posted
    cash: i64,
};

/// Takes cash for a sale, then pays points from it.
///
/// Example:
///   in: { "id": "sale-1", "amount": 100 }
///   out: { "transfer": "a1b2c3d4e5f60718293a4b5d", "made_for": "kiosk", "cash": 0 }
pub const Buy = publr.operation.define(BuyIn, BuyOut, .{
    .name = "buy",
    .kind = .write,
    .run = buy,
});

fn buy(ctx: *publr.Ctx, in: BuyIn) publr.Error!BuyOut {
    std.debug.assert(in.id.len > 0);

    const unit = publr.ledger.unit("PLN");
    const cash = try Ledger.open(ctx, .cash, .{
        .unit = unit,
    });
    const sales = try Ledger.open(ctx, .sales, .{
        .unit = unit,
    });

    _ = try Ledger.transfer(ctx, .{
        .id = in.id,
        .debit = cash,
        .credit = sales,
        .amount = in.amount,
        .reason = .sold,
    });

    const paid = try ctx.call(PointsPay, .{
        .from = cash,
        .id = in.id,
        .amount = in.amount,
    });
    const balance = try publr.ledger.balance(ctx, cash);

    return .{
        .transfer = paid.transfer,
        .made_for = paid.made_for,
        .cash = balance.posted,
    };
}

pub const TargetIn = struct {
    /// Another plugin's account
    account: []const u8,
};

pub const TargetOut = struct {
    /// The refusal met, by name; empty when none
    failure: []const u8,
    /// Its posted balance, when read
    posted: i64,
};

/// Moves another plugin's account itself: refused.
///
/// Example:
///   in: { "account": "a1b2c3d4e5f60718293a4b5c" }
///   out: { "failure": "NotYours", "posted": 0 }
pub const Raid = publr.operation.define(TargetIn, TargetOut, .{
    .name = "raid",
    .kind = .write,
    .run = raid,
});

fn raid(ctx: *publr.Ctx, in: TargetIn) publr.Error!TargetOut {
    std.debug.assert(in.account.len > 0);

    const cash = try Ledger.open(ctx, .cash, .{
        .unit = publr.ledger.unit("PLN"),
    });

    _ = Ledger.transfer(ctx, .{
        .id = "raid",
        .debit = .{
            .id = in.account,
        },
        .credit = cash,
        .amount = 1,
        .reason = .sold,
    }) catch |err| switch (err) {
        error.Failed => {},
        else => return err,
    };

    return .{
        .failure = ctx.failure(),
        .posted = 0,
    };
}

/// Reads another plugin's account, which its `ledger.read` grant names.
///
/// Example:
///   in: { "account": "a1b2c3d4e5f60718293a4b5c" }
///   out: { "failure": "", "posted": 0 }
pub const Peek = publr.operation.define(TargetIn, TargetOut, .{
    .name = "peek",
    .kind = .read,
    .run = peek,
});

fn peek(ctx: *publr.Ctx, in: TargetIn) publr.Error!TargetOut {
    std.debug.assert(in.account.len > 0);

    const balance = try publr.ledger.balance(ctx, .{
        .id = in.account,
    });

    return .{
        .failure = "",
        .posted = balance.posted,
    };
}

pub const plugin = publr.plugin.define(manifest, .{
    .ledger = Ledger,
    .operations = &.{ Buy, Raid, Peek },
    .depends_on = &.{"points"},
    .remotes = &.{PointsPay},
    .permissions = &.{
        .{
            .key = "call:points.pay",
            .reason = "Pays points from its cash",
        },
        .{
            .key = "ledger.read",
            .plugins = &.{"points"},
            .reason = "Shows what a member holds",
        },
    },
});
