//! The ledger's reads: an account's balance (as of a time too), its history, transfers about
//! a record, totals per reason and one transfer. A plugin reads its own accounts, those the
//! plugin that called it handed over, and those of plugins its `ledger.read` grant names; a
//! person reads what their role reaches.
const operation = @import("../../operation.zig");
const shown = @import("shown.zig");

const Docs = operation.Docs;
const Shown = shown.Shown;
const Line = shown.Line;
const Sum = shown.Sum;
const example_shown = shown.example_shown;
const example_account = "0190c8a3d2e1000014f2a6b9";
const example_transfer = "0190c8a3d2e2000027c3d4e5";

pub const Balance = struct {
    pub const name = "ledger.balance";
    /// Plugin code calls it for whoever the request is for, visitors too, held to the
    /// plugin's own reach.
    pub const plugins_only = true;
    pub const description = "An account's balance";
    pub const details =
        \\Its unit, posted balance, pending holds, what is available once every hold posts,
        \\and its four totals; with `at`, the posted balance as it stood then. Balances are
        \\read on the side the account's kind grows on.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        account: []const u8,
        at: ?i64 = null,
    };
    pub const Out = struct {
        unit: []const u8,
        posted: i64,
        pending: i64,
        available: i64,
        debits_posted: i64,
        credits_posted: i64,
        debits_pending: i64,
        credits_pending: i64,
    };
    pub const example: In = .{
        .account = example_account,
    };
    pub const example_out: Out = .{
        .unit = "loyalty.points",
        .posted = 1200,
        .pending = -500,
        .available = 700,
        .debits_posted = 0,
        .credits_posted = 1200,
        .debits_pending = 500,
        .credits_pending = 0,
    };
    pub const field_docs: Docs(In) = .{
        .account = "The account",
        .at = "A time (ms): the posted balance as it stood then",
    };
    pub const output_docs: Docs(Out) = .{
        .unit = "What it counts",
        .posted = "The posted balance",
        .pending = "Its holds, net",
        .available = "The balance once every hold posts",
        .debits_posted = "Debits posted",
        .credits_posted = "Credits posted",
        .debits_pending = "Debits pending",
        .credits_pending = "Credits pending",
    };
};

pub const History = struct {
    pub const name = "ledger.history";
    /// Plugin code calls it for whoever the request is for, visitors too, held to the
    /// plugin's own reach.
    pub const plugins_only = true;
    pub const description = "An account's transfers, newest first";
    pub const details =
        \\A page of the account's transfers, newest first: each with its side, its amount on
        \\this account (positive when it grows the balance), the balance after it and its
        \\status. The next page starts `before` the last one shown.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        account: []const u8,
        about: []const u8 = "",
        from: ?i64 = null,
        to: ?i64 = null,
        before: []const u8 = "",
        limit: u32 = 50,
    };
    pub const Out = struct {
        lines: []const Line,
        /// Where the next page starts; empty after the last.
        before: []const u8,
    };
    pub const example: In = .{
        .account = example_account,
    };
    pub const example_out: Out = .{
        .lines = &.{},
        .before = "",
    };
    pub const field_docs: Docs(In) = .{
        .account = "The account",
        .about = "Only transfers about this record",
        .from = "From this time (ms)",
        .to = "Before this time (ms)",
        .before = "Transfers before this one: the next page",
        .limit = "1 to 200",
    };
    pub const output_docs: Docs(Out) = .{
        .lines = "Newest first",
        .before = "The next page's `before`; empty after the last",
    };
};

pub const Find = struct {
    pub const name = "ledger.find";
    /// Plugin code calls it for whoever the request is for, visitors too, held to the
    /// plugin's own reach.
    pub const plugins_only = true;
    pub const description = "Transfers about a record, on an account or of a reason";
    pub const details =
        \\A page of the transfers on accounts the caller may read that match every filter
        \\given: about a record, about a finer one (`detail`), on one account, on the
        \\accounts of one name, of one reason. At least one of `about`, `detail`, `account`
        \\and `name`; each is read through an index. Oldest first, or `newest` first; a page
        \\is 50 unless `limit` says, 200 at most, and the next starts `after` the last.
        \\For sums, ask `ledger.totals`: it adds up in the database and reads no transfer.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        about: []const u8 = "",
        detail: []const u8 = "",
        reason: []const u8 = "",
        account: []const u8 = "",
        /// The caller's accounts of this name; with `plugin`, another's it may read.
        name: []const u8 = "",
        plugin: []const u8 = "",
        after: []const u8 = "",
        limit: u32 = 50,
        newest: bool = false,
    };
    pub const Out = struct {
        transfers: []const Shown,
        next: []const u8,
    };
    pub const example: In = .{
        .about = "0190c8a3d2e3000031d4e5f6",
    };
    pub const example_out: Out = .{
        .transfers = &.{example_shown},
        .next = "",
    };
    pub const field_docs: Docs(In) = .{
        .about = "The record they are about",
        .detail = "The finer record they are about",
        .reason = "Only transfers of this reason",
        .account = "Only transfers on this account, either side",
        .name = "Only transfers on the accounts of this name",
        .plugin = "Whose accounts the name is; the caller's own when left out",
        .after = "Transfers past this one: the next page",
        .limit = "1 to 200; 50 when left out",
        .newest = "Newest first; oldest first when left out",
    };
    pub const output_docs: Docs(Out) = .{
        .transfers = "In the order asked",
        .next = "The next page's `after`; empty after the last",
    };
};

pub const Totals = struct {
    pub const name = "ledger.totals";
    /// Plugin code calls it for whoever the request is for, visitors too, held to the
    /// plugin's own reach.
    pub const plugins_only = true;
    pub const description = "Debits and credits per reason over matching transfers";
    pub const details =
        \\Posted and open-hold amounts per reason and unit over the transfers that match:
        \\about a record, on one account, or on the caller's accounts of one name, between
        \\two times, of one reason, about a finer record (`detail`). On an account (or a
        \\name) each amount is on its debit or credit side; about a record alone, each
        \\transfer counts once on both. With `details` (up to 200 finer records: a page of
        \\an order's charges) there is one sum per detail, reason and unit, so a page's
        \\figures are one read. Added up in the database: no transfer is read. A page of 200
        \\sums at a time, by detail, reason and unit: `next` continues it.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        about: []const u8 = "",
        detail: []const u8 = "",
        details: []const []const u8 = &.{},
        reason: []const u8 = "",
        account: []const u8 = "",
        /// The caller's accounts of this name; with `plugin`, another's it may read.
        name: []const u8 = "",
        plugin: []const u8 = "",
        from: ?i64 = null,
        to: ?i64 = null,
        after: []const u8 = "",
    };
    pub const Out = struct {
        totals: []const Sum,
        next: []const u8 = "",
    };
    pub const example: In = .{
        .about = "0190c8a3d2e3000031d4e5f6",
    };
    pub const example_out: Out = .{
        .totals = &.{},
    };
    pub const field_docs: Docs(In) = .{
        .about = "The record they are about",
        .detail = "The finer record they are about",
        .details = "Finer records, up to 200: one sum per detail, reason and unit",
        .reason = "Only transfers of this reason",
        .account = "One account",
        .name = "An account name",
        .plugin = "Whose accounts the name is; the caller's own when left out",
        .from = "From this time (ms)",
        .to = "Before this time (ms)",
        .after = "The page after this sum: the `next` the last page answered",
    };
    pub const output_docs: Docs(Out) = .{
        .totals = "One per reason and unit; per detail too when `details` were named",
        .next = "The next page's `after`; empty after the last",
    };
};

pub const Get = struct {
    pub const name = "ledger.get";
    /// Plugin code calls it for whoever the request is for, visitors too, held to the
    /// plugin's own reach.
    pub const plugins_only = true;
    pub const description = "One transfer";
    pub const details =
        \\A transfer by core's id (`transfer`), or by the calling plugin's own id (`id`):
        \\everything it holds, with what settled it, the hold it settles, its conversion's
        \\other leg.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        transfer: []const u8 = "",
        id: []const u8 = "",
    };
    pub const Out = Shown;
    pub const example: In = .{
        .transfer = example_transfer,
    };
    pub const example_out: Out = example_shown;
    pub const field_docs: Docs(In) = .{
        .transfer = "The transfer, by core's id",
        .id = "The transfer, by the calling plugin's own id",
    };
    pub const output_docs: Docs(Out) = .{
        .transfer = "Core's id",
        .maker = "The plugin that made it",
        .maker_id = "Its maker's id for it; empty for a post, void or expiry",
        .made_for = "The plugin whose account it moved by being handed it; empty if none",
        .action = "transfer, hold, post, void, expire, reverse or convert",
        .status = "posted, pending, voided or expired",
        .debit = "The account debited",
        .debit_owner = "Its owner",
        .debit_name = "Its name",
        .credit = "The account credited",
        .credit_owner = "Its owner",
        .credit_name = "Its name",
        .unit = "What it counts",
        .amount = "In the unit's smallest step",
        .reason = "Its maker's reason",
        .reason_label = "The reason in words",
        .hold = "The hold it settles",
        .settled_by = "What settled this hold",
        .reverses = "The transfer it undoes",
        .reversals = "Its reversals, oldest first; the first 200",
        .pair = "A conversion's other leg",
        .rate = "A conversion's rate, in millionths",
        .source = "Where the rate came from",
        .chain = "The first transfer of the chain it was posted in",
        .about = "What it belongs to",
        .detail = "A finer record",
        .author = "A person's id, else the plugin, job or visitor",
        .expires_at = "A hold's expiry",
        .happened_at = "When it happened in the world",
        .posted_at = "When the ledger took it",
        .debit_after = "The debit account's posted balance after it",
        .credit_after = "The credit account's posted balance after it",
    };
};
