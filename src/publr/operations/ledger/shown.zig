//! A transfer as the ledger's reads answer it: whole, as a line of an account's history, and
//! added up per reason.
const ledger = @import("../../model/ledger.zig");

const example_account = "0190c8a3d2e1000014f2a6b9";
const example_transfer = "0190c8a3d2e2000027c3d4e5";

/// A transfer as reads answer it, with its accounts' owners and names and its status.
pub const Shown = struct {
    transfer: []const u8,
    maker: []const u8,
    maker_id: []const u8,
    made_for: []const u8,
    action: []const u8,
    status: ledger.Status,
    debit: []const u8,
    debit_owner: []const u8,
    debit_name: []const u8,
    credit: []const u8,
    credit_owner: []const u8,
    credit_name: []const u8,
    unit: []const u8,
    amount: i64,
    reason: []const u8,
    reason_label: []const u8,
    /// A post's, void's or expiry's: the hold it settles.
    hold: []const u8,
    /// A hold's: what settled it; empty while open.
    settled_by: []const u8,
    reverses: []const u8,
    /// Its reversals, oldest first: `ledger.get` answers them, the lists leave them out.
    reversals: []const []const u8 = &.{},
    /// A conversion's: its other leg.
    pair: []const u8,
    rate: i64,
    source: []const u8,
    chain: []const u8,
    about: []const u8,
    detail: []const u8,
    author: []const u8,
    expires_at: ?i64,
    happened_at: i64,
    posted_at: i64,
    debit_after: i64,
    credit_after: i64,
};

pub const example_shown: Shown = .{
    .transfer = example_transfer,
    .maker = "loyalty",
    .maker_id = "earned-1042",
    .made_for = "",
    .action = "transfer",
    .status = .posted,
    .debit = "0190c8a3d2e1000015a7b8c9",
    .debit_owner = "loyalty",
    .debit_name = "given",
    .credit = example_account,
    .credit_owner = "loyalty",
    .credit_name = "held",
    .unit = "loyalty.points",
    .amount = 500,
    .reason = "earned",
    .reason_label = "Earned on an order",
    .hold = "",
    .settled_by = "",
    .reverses = "",
    .pair = "",
    .rate = 0,
    .source = "",
    .chain = example_transfer,
    .about = "",
    .detail = "",
    .author = "loyalty",
    .expires_at = null,
    .happened_at = 1_790_000_000_000,
    .posted_at = 1_790_000_000_000,
    .debit_after = 500,
    .credit_after = 500,
};

pub const Side = enum { debit, credit };

/// One transfer as an account's history shows it.
pub const Line = struct {
    transfer: []const u8,
    action: []const u8,
    status: ledger.Status,
    reason: []const u8,
    reason_label: []const u8,
    maker: []const u8,
    other: []const u8,
    other_owner: []const u8,
    other_name: []const u8,
    side: Side,
    /// On this account's side: positive when it grows the balance.
    amount: i64,
    balance_after: i64,
    about: []const u8,
    detail: []const u8,
    author: []const u8,
    happened_at: i64,
    posted_at: i64,
};

/// What transfers of one reason and unit add up to.
pub const Sum = struct {
    reason: []const u8,
    reason_label: []const u8,
    unit: []const u8,
    /// The finer record the sum is of, when sums were asked for `details`; empty otherwise.
    detail: []const u8 = "",
    debits_posted: i64,
    credits_posted: i64,
    debits_pending: i64,
    credits_pending: i64,
};
