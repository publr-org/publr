//! Tips points on the sampler's own ledger, then tries to spend twice as many.
//!
//! The ledger's calls both ways: two accounts opened, a transfer under the caller's id (sent
//! again, it moves nothing), a balance read, and a spend past the floor refused by name and
//! in words. Then what the plugin asks of its ctx: whether it may call its own greeting and
//! core's list of accounts, and the balance read again as the plugin alone, nobody behind it.
//!
//! Example:
//!   in: { "id": "t1", "points": 5 }
//!   out: { "made": true, "posted": 5, "refused": "Overdrawn",
//!     "said": "This would break an account's limit", "may_greet": true,
//!     "may_list_users": false, "alone_posted": 5, "alone_signed_in": false }
const publr = @import("publr");
const std = @import("std");
const Books = @import("../ledger.zig");
const Hello = @import("hello.zig");

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
    /// What that refusal says to people
    said: []const u8,
    /// Whether the plugin may call its own greeting
    may_greet: bool,
    /// Whether the plugin may list core's accounts, which it holds no grant for
    may_list_users: bool,
    /// Points held, read as the plugin alone
    ///
    /// Why: a ledger amount, in its unit's smallest step.
    alone_posted: i64,
    /// Whether the plugin alone has anyone signed in behind it
    alone_signed_in: bool,
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

    const refused = ctx.failure();
    const said = ctx.failure_message();
    const alone = try ctx.as_plugin();

    return .{
        .made = tipped.made,
        .posted = balance.posted,
        .refused = refused,
        .said = said,
        .may_greet = ctx.may(Hello.operation),
        .may_list_users = ctx.may(publr.operations.user.List),
        .alone_posted = (try publr.ledger.balance(alone, held)).posted,
        .alone_signed_in = alone.caller().signed_in(),
    };
}

pub const operation = publr.operation.define(In, Out, .{
    .name = "tip",
    .kind = .write,
    .run = run,
});
