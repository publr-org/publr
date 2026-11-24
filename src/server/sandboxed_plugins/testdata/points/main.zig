//! Loyalty points on the core ledger: the plugin the ledger is tested with.
//!
//! Members earn points the shop gives, spend them through holds posted or voided, swap them
//! for money in a wallet, and get them back by reversals. `act` runs one thing at a time and
//! answers the refusal it met by name, so a test reads every one of the ledger's refusals.
//! `pay` takes money onto its till from the account its caller hands over.
const std = @import("std");
const publr = @import("publr");

const manifest: publr.Manifest = .{
    .name = "points",
    .version = "0.1.0",
};

/// Points
///
/// Earned on purchases, spent as a discount.
pub const Ledger = publr.ledger.define(struct {
    /// Points held
    ///
    /// What a member has to spend.
    held: publr.ledger.Liability(.{
        .never_below_zero = true,
    }),
    /// Points given
    given: publr.ledger.Expense(.{}),
    /// Wallet
    wallet: publr.ledger.Liability(.{}),
    /// Exchange
    exchange: publr.ledger.Asset(.{}),
    /// Till
    till: publr.ledger.Asset(.{}),
}, .{
    .reasons = Reason,
    .units = Units,
});

pub const Reason = enum {
    /// Earned on an order
    earned,
    /// Spent at checkout
    spent,
    /// Swapped for money
    exchanged,
    /// Taken back
    returned,
    /// Paid at the till
    paid,
};

pub const Units = struct {
    /// Points
    points: publr.ledger.Unit(.{
        .scale = 0,
        .symbol = "pt",
    }),
};

/// A note
///
/// Kept beside a move, to show a refused chain takes it back too.
pub const Note = struct {
    /// Text
    text: []const u8,
};

pub const Notes = publr.record.define(Note, .{
    .name = "points.note",
    .internal = true,
    .indexed = &.{.text},
});

pub const Action = enum {
    earn,
    hold,
    post,
    void,
    spend,
    chain_fail,
    chain_caught,
    reverse,
    convert,
    mismatch,
    unbalanced,
    close,
    reopen,
    move_other,
    read_other,
    huge,
    balance,
};

pub const ActIn = struct {
    /// What to do
    action: Action,
    /// The member, by account id
    member: []const u8 = "ada",
    /// The plugin's own id for the move
    id: []const u8 = "",
    /// How many points
    ///
    /// Why: a ledger amount, in its unit's smallest step.
    amount: i64 = 0,
    /// A hold's minutes, a reversal's transfer, another plugin's account
    minutes: i64 = 0,
    /// A transfer or account by core's id
    target: []const u8 = "",
};

pub const ActOut = struct {
    /// The refusal met, by name; empty when none
    failure: []const u8,
    /// The transfer made or answered
    transfer: []const u8,
    /// What moved
    ///
    /// Why: a ledger amount, in its unit's smallest step.
    amount: i64,
    /// Whether this call made it
    made: bool,
    /// The member's points held, posted
    posted: i64,
    /// The member's points available once every hold posts
    available: i64,
    /// The member's account
    account: []const u8,
    /// How many notes are kept
    notes: u32,
};

/// Runs one ledger step for a member and answers what the ledger said.
///
/// Example:
///   in: { "action": "balance" }
///   out: { "failure": "", "transfer": "", "amount": 0, "made": false, "posted": 0,
///     "available": 0, "account": "", "notes": 0 }
pub const Act = publr.operation.define(ActIn, ActOut, .{
    .name = "act",
    .kind = .write,
    .run = act,
});

fn act(ctx: *publr.Ctx, in: ActIn) publr.Error!ActOut {
    std.debug.assert(in.member.len > 0);

    const unit = publr.ledger.unit("points.points");
    const held = try Ledger.open(ctx, .held, .{
        .holder = .{
            .person = .{
                .id = in.member,
            },
        },
        .unit = unit,
    });
    const given = try Ledger.open(ctx, .given, .{
        .unit = unit,
    });
    const done = stepped(ctx, in, held, given) catch |err| switch (err) {
        error.Failed => if (in.action == .chain_fail) return err else publr.ledger.Done{
            .transfer = null,
            .amount = 0,
            .made = false,
        },
        else => return err,
    };
    const failure = ctx.failure();
    const balance = try publr.ledger.balance(ctx, held);
    const notes = if (in.id.len > 0) try Notes.page(ctx, .text, in.id, .{
        .limit = 10,
    }) else &.{};

    return .{
        .failure = failure,
        .transfer = if (done.transfer) |ref| ref.id else "",
        .amount = done.amount,
        .made = done.made,
        .posted = balance.posted,
        .available = balance.available,
        .account = held.id,
        .notes = @intCast(notes.len),
    };
}

fn stepped(
    ctx: *publr.Ctx,
    in: ActIn,
    held: publr.ledger.Account,
    given: publr.ledger.Account,
) publr.Error!publr.ledger.Done {
    const nothing: publr.ledger.Done = .{
        .transfer = null,
        .amount = 0,
        .made = false,
    };

    return switch (in.action) {
        .earn => Ledger.transfer(ctx, .{
            .id = in.id,
            .debit = given,
            .credit = held,
            .amount = in.amount,
            .reason = .earned,
        }),
        .spend => Ledger.transfer(ctx, .{
            .id = in.id,
            .debit = held,
            .credit = given,
            .amount = in.amount,
            .reason = .spent,
            .up_to = in.minutes > 0,
        }),
        .hold => Ledger.hold(ctx, .{
            .id = in.id,
            .debit = held,
            .credit = given,
            .amount = in.amount,
            .reason = .spent,
            .expires_at = if (in.minutes > 0) ctx.now().add_minutes(in.minutes) else null,
        }),
        .post => Ledger.post_hold(ctx, .{
            .hold = in.id,
            .amount = if (in.amount > 0) in.amount else null,
        }),
        .void => Ledger.void_hold(ctx, .{
            .hold = in.id,
        }),
        .reverse => Ledger.reverse(ctx, .{
            .id = in.id,
            .transfer = .{
                .id = in.target,
            },
            .amount = if (in.amount > 0) in.amount else null,
            .reason = .returned,
        }),
        .chain_fail => chain_failing(ctx, held, given, in),
        .chain_caught => caught: {
            _ = chain_failing(ctx, held, given, in) catch |err| switch (err) {
                error.Failed => break :caught nothing,
                else => return err,
            };

            break :caught nothing;
        },
        .convert => converted(ctx, held, in),
        .mismatch => mismatched(ctx, held, in),
        .unbalanced => Ledger.transfer(ctx, .{
            .id = in.id,
            .debit = held,
            .credit = held,
            .amount = 1,
            .reason = .earned,
        }),
        .close => closed(ctx, held, true),
        .reopen => closed(ctx, held, false),
        .move_other => Ledger.transfer(ctx, .{
            .id = in.id,
            .debit = given,
            .credit = .{
                .id = in.target,
            },
            .amount = 1,
            .reason = .earned,
        }),
        .read_other => read: {
            _ = try publr.ledger.balance(ctx, .{
                .id = in.target,
            });

            break :read nothing;
        },
        .huge => Ledger.transfer(ctx, .{
            .id = in.id,
            .debit = given,
            .credit = held,
            .amount = std.math.maxInt(i64),
            .reason = .earned,
        }),
        .balance => nothing,
    };
}

/// A note kept, then a chain whose second step breaks the member's limit.
fn chain_failing(
    ctx: *publr.Ctx,
    held: publr.ledger.Account,
    given: publr.ledger.Account,
    in: ActIn,
) publr.Error!publr.ledger.Done {
    std.debug.assert(in.id.len > 0);

    _ = try Notes.create(ctx, .{
        .text = in.id,
    });

    const first = try ctx.print("{s}-a", .{in.id});
    const second = try ctx.print("{s}-b", .{in.id});
    const done = try Ledger.chain(ctx, &.{
        .{
            .transfer = .{
                .id = first,
                .debit = given,
                .credit = held,
                .amount = in.amount,
                .reason = .earned,
            },
        },
        .{
            .transfer = .{
                .id = second,
                .debit = held,
                .credit = given,
                .amount = in.amount * 3,
                .reason = .spent,
            },
        },
    });

    return done[0];
}

fn converted(ctx: *publr.Ctx, held: publr.ledger.Account, in: ActIn) publr.Error!publr.ledger.Done {
    std.debug.assert(in.amount > 0);

    const exchange_points = try Ledger.open(ctx, .exchange, .{
        .unit = publr.ledger.unit("points.points"),
    });
    const exchange_pln = try Ledger.open(ctx, .exchange, .{
        .unit = publr.ledger.unit("PLN"),
    });
    const wallet = try Ledger.open(ctx, .wallet, .{
        .holder = .{
            .person = .{
                .id = in.member,
            },
        },
        .unit = publr.ledger.unit("PLN"),
    });
    const done = try Ledger.convert(ctx, .{
        .id = in.id,
        .from = .{
            .debit = held,
            .credit = exchange_points,
        },
        .to = .{
            .debit = exchange_pln,
            .credit = wallet,
        },
        .amount = in.amount,
        .rate = try publr.Decimal(6).parse("0.015"),
        .source = "points table",
        .reason = .exchanged,
    });

    return done.to;
}

fn mismatched(
    ctx: *publr.Ctx,
    held: publr.ledger.Account,
    in: ActIn,
) publr.Error!publr.ledger.Done {
    std.debug.assert(in.id.len > 0);

    const wallet = try Ledger.open(ctx, .wallet, .{
        .holder = .{
            .person = .{
                .id = in.member,
            },
        },
        .unit = publr.ledger.unit("PLN"),
    });

    return Ledger.transfer(ctx, .{
        .id = in.id,
        .debit = wallet,
        .credit = held,
        .amount = 1,
        .reason = .earned,
    });
}

fn closed(ctx: *publr.Ctx, held: publr.ledger.Account, close: bool) publr.Error!publr.ledger.Done {
    std.debug.assert(held.id.len > 0);

    if (close) {
        try Ledger.close(ctx, held);
    } else {
        try Ledger.reopen(ctx, held);
    }

    return .{
        .transfer = null,
        .amount = 0,
        .made = false,
    };
}

pub const PayIn = struct {
    /// The caller's own account the money comes from
    from: publr.ledger.Account,
    /// The caller's id for the payment
    id: []const u8,
    /// In grosze
    ///
    /// Why: a ledger amount, in its unit's smallest step.
    amount: i64,
};

pub const PayOut = struct {
    /// The transfer
    transfer: []const u8,
    /// The plugin it was made for
    made_for: []const u8,
};

/// Takes money onto the till from the account the caller hands over.
///
/// Example:
///   in: { "from": "a1b2c3d4e5f60718293a4b5c", "id": "sale-1", "amount": 100 }
///   out: { "transfer": "a1b2c3d4e5f60718293a4b5d", "made_for": "kiosk" }
pub const Pay = publr.operation.define(PayIn, PayOut, .{
    .name = "pay",
    .kind = .write,
    .run = pay,
});

fn pay(ctx: *publr.Ctx, in: PayIn) publr.Error!PayOut {
    std.debug.assert(in.id.len > 0);

    const till = try Ledger.open(ctx, .till, .{
        .unit = publr.ledger.unit("PLN"),
    });
    const done = try Ledger.transfer(ctx, .{
        .id = in.id,
        .debit = till,
        .credit = in.from,
        .amount = in.amount,
        .reason = .paid,
    });
    const shown = try publr.ledger.get(ctx, done.transfer.?);

    return .{
        .transfer = shown.transfer,
        .made_for = shown.made_for,
    };
}

pub const plugin = publr.plugin.define(manifest, .{
    .records = &.{Notes},
    .ledger = Ledger,
    .operations = &.{ Act, Pay },
});
