//! Tips points on the sampler's own ledger, then tries to spend twice as many.
//!
//! The ledger's calls both ways: two accounts opened, a transfer under the caller's id (sent
//! again, it moves nothing), a balance read, and a spend past the floor refused by name.
//!
//! Example:
//!   in: { "id": "t1", "points": 5 }
//!   out: { "made": true, "posted": 5, "refused": "Overdrawn" }
const publr = @import("publr");
const std = @import("std");
const Books = @import("../ledger.zig");

const Ledger = Books.Ledger;

pub const In = struct {
    /// The caller's id for the tip
    id: []const u8,
    /// How many points
    ///
    /// Why: a ledger amount, in its unit's smallest step.
    points: i64,
};

pub const Out = struct {
    /// Whether this call moved the points
    made: bool,
    /// Points held now
    ///
    /// Why: a ledger amount, in its unit's smallest step.
    posted: i64,
    /// How the spend past the floor was refused
    refused: []const u8,
};

fn run(ctx: *publr.Ctx, in: In) publr.Error!Out {
    std.debug.assert(in.id.len > 0);

    const unit = publr.ledger.unit("sampler.points");
    const held = try Ledger.open(ctx, .held, .{
        .unit = unit,
    });
    const given = try Ledger.open(ctx, .given, .{
        .unit = unit,
    });
    const tipped = try Ledger.transfer(ctx, .{
        .id = in.id,
        .debit = given,
        .credit = held,
        .amount = in.points,
        .reason = .tipped,
    });
    const balance = try publr.ledger.balance(ctx, held);

    _ = Ledger.transfer(ctx, .{
        .id = try ctx.print("{s}-spend", .{in.id}),
        .debit = held,
        .credit = given,
        .amount = balance.posted * 2 + 1,
        .reason = .spent,
    }) catch |err| switch (err) {
        error.Failed => {},
        else => return err,
    };

    return .{
        .made = tipped.made,
        .posted = balance.posted,
        .refused = ctx.failure(),
    };
}

pub const operation = publr.operation.define(In, Out, .{
    .name = "tip",
    .kind = .write,
    .run = run,
});
