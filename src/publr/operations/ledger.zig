//! The double-entry ledger, after TigerBeetle: accounts that count one unit for one owner
//! plugin, and transfers between them that are never changed or removed. Plugin code moves
//! its own accounts (`publr.ledger.define`'s handle calls these); people and agents only
//! read.
const operation = @import("../operation.zig");
const event_define = @import("../plugin/hook_define.zig").event;
const moves = @import("ledger/moves.zig");
const reads = @import("ledger/reads.zig");
const shown = @import("ledger/shown.zig");
const accounts = @import("ledger/accounts.zig");

pub const namespace: operation.Namespace = .{
    .name = "ledger",
    .label = "Ledger",
    .area = .system,
    .summary = "Exact counted balances: accounts, transfers, holds",
    .details =
    \\Accounts that count one unit (a currency, or points, credits, pieces a plugin
    \\declares) for the plugin that opened them, and transfers between them, never changed
    \\or removed: every balance is what its transfers add up to. Only plugin code moves
    \\money, through the plugin's own accounts or those the plugin that called it handed
    \\over; people and agents read. Refusals are named: NotYours, NoAccount, Closed,
    \\UnitMismatch, Unbalanced, Overdrawn, Taken, NoHold, OverHold, Settled, Expired,
    \\OverReversed, TooLarge.
    ,
};

pub const HolderKind = moves.HolderKind;
pub const StepAction = moves.StepAction;
pub const Step = moves.Step;
pub const Done = moves.Done;
pub const Open = moves.Open;
pub const Transfer = moves.Transfer;
pub const Hold = moves.Hold;
pub const PostHold = moves.PostHold;
pub const VoidHold = moves.VoidHold;
pub const Chain = moves.Chain;
pub const Reverse = moves.Reverse;
pub const Convert = moves.Convert;
pub const Close = moves.Close;
pub const Reopen = moves.Reopen;

pub const Balance = reads.Balance;
pub const BalanceOut = reads.Balance.Out;
pub const History = reads.History;
pub const HistoryOut = reads.History.Out;
pub const Find = reads.Find;
pub const Totals = reads.Totals;
pub const Get = reads.Get;
pub const Shown = shown.Shown;
pub const Side = shown.Side;
pub const Line = shown.Line;
pub const Sum = shown.Sum;

pub const Accounts = accounts.Accounts;
pub const AccountsOut = accounts.Accounts.Out;
pub const Account = accounts.Account;
pub const AccountView = accounts.AccountView;
pub const Check = accounts.Check;
pub const UnitLine = accounts.UnitLine;
pub const Differing = accounts.Differing;

/// A hold voided by its expiry, as its owner hears it.
pub const Expired = event_define(.{
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
