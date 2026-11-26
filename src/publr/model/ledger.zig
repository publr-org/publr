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
