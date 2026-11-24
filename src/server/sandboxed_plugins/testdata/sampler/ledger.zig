//! The sampler's books: points tipped to whoever asks, never below zero.
const publr = @import("publr");

/// Tips
///
/// Points the sampler gives out.
pub const Ledger = publr.ledger.define(struct {
    /// Tips held
    ///
    /// What was tipped, to spend.
    held: publr.ledger.Liability(.{
        .never_below_zero = true,
    }),
    /// Tips given
    given: publr.ledger.Expense(.{}),
}, .{
    .reasons = Reason,
    .units = Units,
});

pub const Reason = enum {
    /// Tipped
    tipped,
    /// Spent
    spent,
};

pub const Units = struct {
    /// Points
    points: publr.ledger.Unit(.{
        .scale = 0,
        .symbol = "pt",
    }),
};
