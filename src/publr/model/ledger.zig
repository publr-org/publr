/// What a ledger account keeps; it gives the side its balance grows on.
pub const Kind = enum {
    asset,
    liability,
    equity,
    income,
    expense,

    /// Assets and expenses grow by debits; liabilities, equity and income by credits.
    pub fn grows_by_debit(kind: Kind) bool {
        return kind == .asset or kind == .expense;
    }
};

/// The one limit an account may keep, holds counted.
pub const Limit = enum {
    none,
    never_below_zero,
    never_above_zero,
};

/// Where a transfer stands. A hold is `pending` until a post, a void or its expiry settles it.
pub const Status = enum {
    posted,
    pending,
    voided,
    expired,
};

/// An account whose totals its transfers do not add up to, as `ledger.check` names it.
pub const Differing = struct {
    account: []const u8,
    debits_posted: i64,
    credits_posted: i64,
    debits_pending: i64,
    credits_pending: i64,
};
