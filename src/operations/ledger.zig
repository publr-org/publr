//! The double-entry ledger, after TigerBeetle: accounts that count one unit for one owner
//! plugin, and transfers between them that are never changed or removed. Plugin code moves
//! its own accounts (`publr.ledger.define`'s handle calls these); people and agents only
//! read. The engine is `ledger/engine.zig`, the reads `ledger/reads.zig`.
const std = @import("std");
const sdk = @import("../sdk.zig");
const engine = @import("ledger/engine.zig");
const reads = @import("ledger/reads.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const Docs = sdk.operation.Docs;

pub const namespace: sdk.operation.Namespace = .{
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

pub const HolderKind = enum { none, record, person };

pub const StepAction = enum { transfer, hold, post_hold, void_hold };

/// One step of a chain, as the typed handle sends it.
pub const Step = struct {
    action: StepAction = .transfer,
    id: []const u8 = "",
    debit: []const u8 = "",
    credit: []const u8 = "",
    /// For a post: 0 posts all of the hold.
    amount: i64 = 0,
    reason: []const u8 = "",
    about: []const u8 = "",
    detail: []const u8 = "",
    happened_at: ?i64 = null,
    up_to: bool = false,
    expires_at: ?i64 = null,
    /// For a post or a void: the hold, by its maker's id.
    hold: []const u8 = "",
};

pub const Done = struct {
    /// Empty when nothing moved (`up_to` with no room).
    transfer: []const u8,
    amount: i64,
    made: bool,
};

const example_account = "0190c8a3d2e1000014f2a6b9";
const example_transfer = "0190c8a3d2e2000027c3d4e5";
const example_done: Done = .{
    .transfer = example_transfer,
    .amount = 500,
    .made = true,
};
const step_docs: Docs(Step) = .{
    .action = "transfer, hold, post_hold or void_hold",
    .id = "The plugin's own id for it: the same id again answers the first",
    .debit = "The account debited",
    .credit = "The account credited",
    .amount = "Positive, in the unit's smallest step; a post's 0 posts the whole hold",
    .reason = "One of the plugin's declared reasons",
    .about = "What it belongs to: an order, a booking",
    .detail = "A finer record: a line, a charge",
    .happened_at = "When it happened in the world; now when left out",
    .up_to = "Move as much as the accounts' limits allow, possibly nothing",
    .expires_at = "A hold's: when core voids it unless settled first",
    .hold = "A post's or void's: the hold, by the plugin's own id",
};
const done_docs: Docs(Done) = .{
    .transfer = "The transfer; empty when nothing moved",
    .amount = "What moved",
    .made = "False when the id had made it before",
};

pub const Open = struct {
    pub const name = "ledger.open";
    /// Plugin code calls it for whoever the request is for, visitors too, held to the
    /// plugin's own reach.
    pub const plugins_only = true;
    pub const description = "Open one of the plugin's ledger accounts";
    pub const details =
        \\The plugin's account of a declared name, for a holder (a record or a person's
        \\account) or a key, counting one unit: a currency or a declared unit, maybe per
        \\record (`inventory.pcs/<id>`). Opened on first use; asked again, the same account
        \\answers. Plugin code only.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        name: []const u8,
        holder_kind: HolderKind = .none,
        holder: []const u8 = "",
        key: []const u8 = "",
        unit: []const u8,
    };
    pub const Out = struct {
        account: []const u8,
        opened: bool,
    };
    pub const example: In = .{
        .name = "held",
        .holder_kind = .person,
        .holder = "u_ada",
        .unit = "loyalty.points",
    };
    pub const example_out: Out = .{
        .account = example_account,
        .opened = true,
    };
    pub const field_docs: Docs(In) = .{
        .name = "One of the plugin's declared account names",
        .holder_kind = "none, record or person",
        .holder = "The record's or the person's account id",
        .key = "A word, when one name has many accounts tied to no record",
        .unit = "An ISO 4217 code or <plugin>.<unit>, maybe /<record id>",
    };
    pub const output_docs: Docs(Out) = .{
        .account = "The account",
        .opened = "False when it was open already",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        return engine.open(ctx, in);
    }
};

/// The parts of a transfer or a hold, as `ledger.transfer` and `ledger.hold` take them.
pub const Transfer = Moving("ledger.transfer", .transfer, "Move an amount between two accounts",
    \\Debits one account and credits another of the same unit, posted at once. The plugin's
    \\own id makes a retry harmless: the same id with the same parts answers the first, any
    \\part different is refused (Taken). Limits are checked inside the write (Overdrawn);
    \\`up_to` moves what they allow. Plugin code only, on its own accounts or those the
    \\plugin that called it handed over.
);

pub const Hold = Moving("ledger.hold", .hold, "Hold an amount, posted or voided later",
    \\A pending transfer: it counts in the pending totals and against limits, not in the
    \\posted balance, until `ledger.post_hold` posts it (the same or less) or
    \\`ledger.void_hold` releases it; at `expires_at` core voids it. Plugin code only.
);

fn Moving(
    comptime operation_name: []const u8,
    comptime action: StepAction,
    comptime said: []const u8,
    comptime detailed: []const u8,
) type {
    return struct {
        pub const name = operation_name;
        /// Plugin code calls it for whoever the request is for, visitors too, held to the
        /// plugin's own reach.
        pub const plugins_only = true;
        pub const description = said;
        pub const details = detailed;
        pub const kind: sdk.operation.Kind = .write;
        pub const In = Step;
        pub const Out = Done;
        pub const example: In = .{
            .action = action,
            .id = "earned-1042",
            .debit = example_account,
            .credit = "0190c8a3d2e1000015a7b8c9",
            .amount = 500,
            .reason = "earned",
        };
        pub const example_out: Out = example_done;
        pub const field_docs = step_docs;
        pub const output_docs = done_docs;

        pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
            var step = in;

            step.action = action;

            const done = try engine.post(ctx, &.{step});

            std.debug.assert(done.len == 1);

            return done[0];
        }
    };
}

pub const PostHold = struct {
    pub const name = "ledger.post_hold";
    /// Plugin code calls it for whoever the request is for, visitors too, held to the
    /// plugin's own reach.
    pub const plugins_only = true;
    pub const description = "Post a hold, all of it or less";
    pub const details =
        \\Posts a hold the plugin made for its amount or less; the rest goes back. More than
        \\the hold is refused (OverHold); a hold settles once (Settled, Expired), and posting
        \\it again for the same amount answers the first post. Plugin code only.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        hold: []const u8,
        amount: i64 = 0,
    };
    pub const Out = Done;
    pub const example: In = .{
        .hold = "cart-77-points",
        .amount = 400,
    };
    pub const example_out: Out = example_done;
    pub const field_docs: Docs(In) = .{
        .hold = "The hold, by the plugin's own id",
        .amount = "What it posts; 0 posts all of it",
    };
    pub const output_docs = done_docs;

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        const done = try engine.post(ctx, &.{.{
            .action = .post_hold,
            .hold = in.hold,
            .amount = in.amount,
        }});

        return done[0];
    }
};

pub const VoidHold = struct {
    pub const name = "ledger.void_hold";
    /// Plugin code calls it for whoever the request is for, visitors too, held to the
    /// plugin's own reach.
    pub const plugins_only = true;
    pub const description = "Release a hold";
    pub const details =
        \\Voids a hold the plugin made: its amount leaves the pending totals. A hold settles
        \\once; voiding it again answers the first void. Plugin code only.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        hold: []const u8,
    };
    pub const Out = Done;
    pub const example: In = .{
        .hold = "cart-77-points",
    };
    pub const example_out: Out = example_done;
    pub const field_docs: Docs(In) = .{
        .hold = "The hold, by the plugin's own id",
    };
    pub const output_docs = done_docs;

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        const done = try engine.post(ctx, &.{.{
            .action = .void_hold,
            .hold = in.hold,
        }});

        return done[0];
    }
};

pub const Chain = struct {
    pub const name = "ledger.chain";
    /// Plugin code calls it for whoever the request is for, visitors too, held to the
    /// plugin's own reach.
    pub const plugins_only = true;
    pub const description = "Post several steps whole or not at all";
    pub const details =
        \\Transfers, holds, posts and voids that stand or fall together, each seeing the ones
        \\before it. Refused, the chain undoes only itself; the caller may go on. Core keeps
        \\which transfers were posted together. Plugin code only.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        steps: []const Step,
    };
    pub const Out = struct {
        done: []const Done,
    };
    pub const example: In = .{
        .steps = &.{Transfer.example},
    };
    pub const example_out: Out = .{
        .done = &.{example_done},
    };
    pub const field_docs: Docs(In) = .{
        .steps = "The steps, in order",
    };
    pub const output_docs: Docs(Out) = .{
        .done = "One answer per step",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        return .{
            .done = try engine.post(ctx, in.steps),
        };
    }
};

pub const Reverse = struct {
    pub const name = "ledger.reverse";
    /// Plugin code calls it for whoever the request is for, visitors too, held to the
    /// plugin's own reach.
    pub const plugins_only = true;
    pub const description = "Undo all or part of a posted transfer";
    pub const details =
        \\The same two accounts the other way, linked to the original, never more than is left
        \\of it after earlier reversals (OverReversed). Its maker reverses it, or the plugin it
        \\was made for. Plugin code only.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        transfer: []const u8,
        amount: i64 = 0,
        reason: []const u8,
    };
    pub const Out = Done;
    pub const example: In = .{
        .id = "clawback-1042",
        .transfer = example_transfer,
        .reason = "returned",
    };
    pub const example_out: Out = example_done;
    pub const field_docs: Docs(In) = .{
        .id = "The plugin's own id for the reversal",
        .transfer = "The transfer it undoes",
        .amount = "How much; 0 reverses what is left",
        .reason = "One of the plugin's declared reasons",
    };
    pub const output_docs = done_docs;

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        return engine.reverse(ctx, in);
    }
};

pub const Convert = struct {
    pub const name = "ledger.convert";
    /// Plugin code calls it for whoever the request is for, visitors too, held to the
    /// plugin's own reach.
    pub const plugins_only = true;
    pub const description = "Move value from one unit to another";
    pub const details =
        \\Two transfers in one chain through the plugin's exchange accounts: the amount from
        \\`from_credit` to `from_debit`, and at `rate` (six places) from `to_credit` to
        \\`to_debit`, rounded down to the target unit's step. Both legs keep the rate and its
        \\source. Plugin code only.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        from_debit: []const u8,
        from_credit: []const u8,
        to_debit: []const u8,
        to_credit: []const u8,
        amount: i64,
        rate: i64,
        source: []const u8,
        reason: []const u8,
        about: []const u8 = "",
        detail: []const u8 = "",
    };
    pub const Out = struct {
        from: Done,
        to: Done,
    };
    pub const example: In = .{
        .id = "wallet-ada-eur-pln-7",
        .from_debit = example_account,
        .from_credit = "0190c8a3d2e1000015a7b8c9",
        .to_debit = "0190c8a3d2e1000016b8c9d0",
        .to_credit = "0190c8a3d2e1000017c9d0e1",
        .amount = 10000,
        .rate = 4_281_700,
        .source = "ECB 2026-11-21",
        .reason = "exchanged",
    };
    pub const example_out: Out = .{
        .from = example_done,
        .to = example_done,
    };
    pub const field_docs: Docs(In) = .{
        .id = "The plugin's own id for the conversion",
        .from_debit = "Debited in the source unit (the exchange account)",
        .from_credit = "Credited in the source unit (the wallet)",
        .to_debit = "Debited in the target unit (the exchange account)",
        .to_credit = "Credited in the target unit (the wallet)",
        .amount = "In the source unit's smallest step",
        .rate = "Target per source, in millionths: 4.2817 is 4281700",
        .source = "Where the rate came from",
        .reason = "One of the plugin's declared reasons",
        .about = "What it belongs to",
        .detail = "A finer record",
    };
    pub const output_docs: Docs(Out) = .{
        .from = "The source leg",
        .to = "The target leg",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        return engine.convert(ctx, in);
    }
};

pub const Close = Closing("ledger.close", true, "Close an account",
    \\A closed account takes no transfer but the voiding of a hold already on it. Plugin
    \\code only, on its own accounts.
);

pub const Reopen = Closing("ledger.reopen", false, "Reopen a closed account",
    \\The account takes transfers again. Plugin code only, on its own accounts.
);

fn Closing(
    comptime operation_name: []const u8,
    comptime closed: bool,
    comptime said: []const u8,
    comptime detailed: []const u8,
) type {
    return struct {
        pub const name = operation_name;
        /// Plugin code calls it for whoever the request is for, visitors too, held to the
        /// plugin's own reach.
        pub const plugins_only = true;
        pub const description = said;
        pub const details = detailed;
        pub const kind: sdk.operation.Kind = .write;
        pub const In = struct {
            account: []const u8,
        };
        pub const Out = struct {
            closed: bool,
        };
        pub const example: In = .{
            .account = example_account,
        };
        pub const example_out: Out = .{
            .closed = closed,
        };
        pub const field_docs: Docs(In) = .{
            .account = "The account",
        };
        pub const output_docs: Docs(Out) = .{
            .closed = "Whether it is closed now",
        };

        pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
            try engine.set_closed(ctx, in.account, closed);

            return .{
                .closed = closed,
            };
        }
    };
}

pub const Balance = reads.Balance;
pub const BalanceOut = reads.Balance.Out;
pub const History = reads.History;
pub const HistoryOut = reads.History.Out;
pub const Find = reads.Find;
pub const Totals = reads.Totals;
pub const Sum = reads.Sum;
pub const Line = reads.Line;
pub const Get = reads.Get;
pub const Shown = reads.Shown;
pub const Accounts = reads.Accounts;
pub const AccountsOut = reads.Accounts.Out;
pub const Account = reads.Account;
pub const Check = reads.Check;
pub const AccountView = reads.AccountView;
pub const UnitLine = @import("ledger/accounts.zig").UnitLine;

/// A hold not settled by its expiry is voided by core, natively, as its own queued job.
pub const expire_job = engine.expire_job;
pub const Expired = engine.Expired;

pub const operations = [_]type{
    Open,   Transfer, Hold,    PostHold, VoidHold, Chain, Reverse,  Convert, Close,
    Reopen, Balance,  History, Find,     Totals,   Get,   Accounts, Account, Check,
};
