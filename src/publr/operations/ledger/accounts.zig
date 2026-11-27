//! Ledger accounts as people and plugins read them, and the full check that every account's
//! totals are what its transfers add up to and every unit's books balance.
const operation = @import("../../operation.zig");
const ledger = @import("../../model/ledger.zig");

const Docs = operation.Docs;
const example_account = "0190c8a3d2e1000014f2a6b9";

/// An account as the ledger's reads answer it.
pub const AccountView = struct {
    account: []const u8,
    owner: []const u8,
    name: []const u8,
    label: []const u8,
    kind: ledger.Kind,
    limit: ledger.Limit,
    holder_kind: []const u8,
    holder: []const u8,
    key: []const u8,
    unit: []const u8,
    /// Decimal places of the unit's smallest step.
    scale: u8,
    posted: i64,
    pending: i64,
    available: i64,
    debits_posted: i64,
    credits_posted: i64,
    debits_pending: i64,
    credits_pending: i64,
    closed: bool,
    created_at: i64,
};

const example_view: AccountView = .{
    .account = example_account,
    .owner = "loyalty",
    .name = "held",
    .label = "Points held",
    .kind = .liability,
    .limit = .never_below_zero,
    .holder_kind = "person",
    .holder = "u_ada",
    .key = "",
    .unit = "loyalty.points",
    .scale = 0,
    .posted = 1200,
    .pending = -500,
    .available = 700,
    .debits_posted = 0,
    .credits_posted = 1200,
    .debits_pending = 500,
    .credits_pending = 0,
    .closed = false,
    .created_at = 1_790_000_000_000,
};

const view_docs: Docs(AccountView) = .{
    .account = "The account",
    .owner = "The plugin that opened it",
    .name = "Its declared name",
    .label = "Its name in words",
    .kind = "asset, liability, equity, income or expense",
    .limit = "none, never_below_zero or never_above_zero",
    .holder_kind = "record, person or empty",
    .holder = "Whose it is",
    .key = "Its key, for a name with many accounts tied to no record",
    .unit = "What it counts",
    .scale = "Decimal places of the unit's smallest step",
    .posted = "The posted balance",
    .pending = "Its holds, net",
    .available = "Once every hold posts",
    .debits_posted = "Debits posted",
    .credits_posted = "Credits posted",
    .debits_pending = "Debits pending",
    .credits_pending = "Credits pending",
    .closed = "Takes no transfer",
    .created_at = "When it was opened",
};

/// One unit's debits and credits over every account.
pub const UnitLine = struct {
    unit: []const u8,
    debits_posted: i64,
    credits_posted: i64,
    /// Debits less credits, posted and pending: zero when the books balance.
    difference: i64,
    in_balance: bool,
};

/// An account whose totals its transfers do not add up to.
pub const Differing = ledger.Differing;

pub const Accounts = struct {
    pub const name = "ledger.accounts";
    /// Plugin code calls it for whoever the request is for, visitors too, held to the
    /// plugin's own reach.
    pub const plugins_only = true;
    pub const description = "Ledger accounts, a page at a time";
    pub const details =
        \\Accounts the caller may read, in the order they were opened, narrowed by the plugin
        \\that owns them, their name, holder or unit. The next page starts `after` the last.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        plugin: []const u8 = "",
        name: []const u8 = "",
        holder: []const u8 = "",
        unit: []const u8 = "",
        after: []const u8 = "",
        limit: u32 = 50,
    };
    pub const Out = struct {
        accounts: []const AccountView,
        next: []const u8,
    };
    pub const example: In = .{
        .plugin = "loyalty",
    };
    pub const example_out: Out = .{
        .accounts = &.{example_view},
        .next = "",
    };
    pub const field_docs: Docs(In) = .{
        .plugin = "Only this plugin's",
        .name = "Only accounts of this name",
        .holder = "Only this holder's (a record's or a person's id)",
        .unit = "Only this unit (and per record of it)",
        .after = "Accounts after this one: the next page",
        .limit = "1 to 200",
    };
    pub const output_docs: Docs(Out) = .{
        .accounts = "In the order they were opened",
        .next = "The next page's `after`; empty after the last",
    };
};

pub const Account = struct {
    pub const name = "ledger.account";
    /// Plugin code calls it for whoever the request is for, visitors too, held to the
    /// plugin's own reach.
    pub const plugins_only = true;
    pub const description = "One ledger account";
    pub const details =
        \\The account's name, kind, holder, unit, limit, balances and its four totals.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        id: []const u8,
    };
    pub const Out = AccountView;
    pub const example: In = .{
        .id = example_account,
    };
    pub const example_out: Out = example_view;
    pub const field_docs: Docs(In) = .{
        .id = "The account",
    };
    pub const output_docs = view_docs;
};

pub const Check = struct {
    pub const name = "ledger.check";
    pub const description = "Check that the books balance";
    pub const details =
        \\Recomputes every account's totals from its transfers and each unit's sums, and
        \\answers what differs: nothing, unless there is a bug. Changes nothing.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        in_balance: bool,
        units: []const UnitLine,
        /// Accounts whose totals their transfers do not add up to.
        accounts: []const Differing,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .in_balance = true,
        .units = &.{},
        .accounts = &.{},
    };
    pub const field_docs: Docs(In) = .{};
    pub const output_docs: Docs(Out) = .{
        .in_balance = "Every unit balances and every account adds up",
        .units = "One line per unit",
        .accounts = "Accounts whose totals differ from their transfers, the first 200 by id; " ++
            "empty when none",
    };
};
