//! `publr.ledger`: a plugin's ledger, declared once beside its records and listed in
//! `define` as `.ledger`. Account names are the fields of a struct, each with its kind and
//! limit; reasons are an enum; units a struct of `publr.ledger.Unit`. The words come from
//! their doc comments. The handle `define` makes moves the plugin's own accounts through
//! core's `ledger.*` operations, compiled in or installed alike.
const std = @import("std");
const model = @import("../../model/ledger.zig");
const operations = @import("../operations/ledger.zig");
const words = @import("words.zig");
const plugin_define = @import("define.zig");
const sdk = @import("../../sdk.zig");
const AnyRef = @import("record_define.zig").AnyRef;
const AccountRef = @import("../account_ref.zig").Account;
const Contract = @import("../model/contract.zig");

pub const Error = sdk.Error;
pub const Kind = @import("../model/ledger.zig").Kind;
pub const Limit = @import("../model/ledger.zig").Limit;

pub const Limits = struct {
    never_below_zero: bool = false,
    never_above_zero: bool = false,
};

/// An account name's kind and limit, as a field's type: `held: publr.ledger.Liability(.{
/// .never_below_zero = true })`.
pub fn Of(comptime kind: Kind, comptime limits: Limits) type {
    comptime {
        if (limits.never_below_zero and limits.never_above_zero) {
            @compileError("a ledger account keeps one limit at most");
        }

        std.debug.assert(@backingInt(kind) <= @backingInt(Kind.expense));
    }

    return struct {
        pub const ledger_kind = kind;
        pub const ledger_limit: Limit = if (limits.never_below_zero)
            .never_below_zero
        else if (limits.never_above_zero)
            .never_above_zero
        else
            .none;
    };
}

pub fn Asset(comptime limits: Limits) type {
    return Of(.asset, limits);
}

pub fn Liability(comptime limits: Limits) type {
    return Of(.liability, limits);
}

pub fn Equity(comptime limits: Limits) type {
    return Of(.equity, limits);
}

pub fn Income(comptime limits: Limits) type {
    return Of(.income, limits);
}

pub fn Expense(comptime limits: Limits) type {
    return Of(.expense, limits);
}

pub const UnitDeclaration = struct {
    scale: u8,
    symbol: []const u8 = "",
};

/// A declared unit, as a field's type: `points: publr.ledger.Unit(.{ .scale = 0 })`.
pub fn Unit(comptime declaration: UnitDeclaration) type {
    comptime {
        if (declaration.scale > 18) {
            @compileError("a unit's scale is at most 18 decimal places");
        }
    }

    return struct {
        pub const ledger_unit = declaration;
    };
}

/// What an account counts: a currency or a declared unit, maybe per record.
pub const UnitName = struct {
    base: []const u8,
    item: []const u8 = "",
};

/// A currency (`"PLN"`) or a declared unit (`"loyalty.points"`).
pub fn unit(comptime name: []const u8) UnitName {
    comptime {
        if (model.unit_of(name) == null or std.mem.indexOfScalar(u8, name, '/') != null) {
            @compileError("`" ++ name ++ "` is no unit: an ISO 4217 code or <plugin>.<unit>");
        }
    }

    return .{
        .base = name,
    };
}

/// A unit counted per record: pieces of this variant (`unit_of("inventory.pcs", variant)`).
pub fn unit_of(comptime name: []const u8, record: anytype) UnitName {
    std.debug.assert(record.id.len > 0);
    std.debug.assert(name.len > 0);

    return .{
        .base = name,
        .item = record.id,
    };
}

/// A ledger account, kept in a record as a reference (`owed: publr.ledger.Account`).
pub const Account = struct {
    id: []const u8,

    pub const json_scalar: Contract.Kind = .string;
    pub const json_label = "a ledger account's id";
    pub const ledger_ref = "ledger_account";
    /// Handed over as it lies; JSON writes its id alone, and reads `{ "id": … }` too.
    pub const publr_form = .lone;

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        parse_options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!Account {
        return parse_ref(Account, allocator, source, parse_options);
    }

    pub fn jsonParseFromValue(
        _: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) std.json.ParseFromValueError!Account {
        return .{
            .id = try id_of(source),
        };
    }

    pub fn jsonStringify(self: Account, writer: anytype) !void {
        std.debug.assert(self.id.len > 0);

        return writer.write(self.id);
    }
};

/// A ledger transfer, kept in a record as a reference (a payment's, a refund's).
pub const TransferRef = struct {
    id: []const u8,

    pub const json_scalar: Contract.Kind = .string;
    pub const json_label = "a ledger transfer's id";
    pub const ledger_ref = "ledger_transfer";
    pub const publr_form = .lone;

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        parse_options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!TransferRef {
        return parse_ref(TransferRef, allocator, source, parse_options);
    }

    pub fn jsonParseFromValue(
        _: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) std.json.ParseFromValueError!TransferRef {
        return .{
            .id = try id_of(source),
        };
    }

    pub fn jsonStringify(self: TransferRef, writer: anytype) !void {
        std.debug.assert(self.id.len > 0);

        return writer.write(self.id);
    }
};

fn parse_ref(
    comptime Ref: type,
    allocator: std.mem.Allocator,
    source: anytype,
    parse_options: std.json.ParseOptions,
) std.json.ParseError(@TypeOf(source.*))!Ref {
    const value = try std.json.innerParse(std.json.Value, allocator, source, parse_options);

    return Ref.jsonParseFromValue(allocator, value, parse_options) catch error.UnexpectedToken;
}

fn id_of(source: std.json.Value) std.json.ParseFromValueError![]const u8 {
    std.debug.assert(model.id_len_max > 0);

    const id = switch (source) {
        .string => |text| text,
        .object => |object| if (object.get("id")) |found| switch (found) {
            .string => |text| text,
            else => return error.UnexpectedToken,
        } else return error.UnexpectedToken,
        else => return error.UnexpectedToken,
    };

    if (id.len == 0 or id.len > model.id_len_max) {
        return error.UnexpectedToken;
    }

    return id;
}

/// Whether a field's type is a ledger reference; its field kind when it is.
pub fn ref_kind(comptime Type: type) ?[]const u8 {
    comptime {
        std.debug.assert(@sizeOf(Type) < 1 << 24);

        if (@typeInfo(Type) != .@"struct" or !@hasDecl(Type, "ledger_ref")) {
            return null;
        }

        return Type.ledger_ref;
    }
}

/// Whose an account is: a record's (an affiliate, a gift card) or a person's.
pub const Holder = struct {
    record: ?AnyRef = null,
    person: ?AccountRef = null,
};

/// An answer to a move: the transfer made, the amount it moved, and whether this call made it
/// (false when the id had made it before).
pub const Done = struct {
    transfer: ?TransferRef,
    amount: i64,
    made: bool,
};

pub const Pair = struct {
    debit: Account,
    credit: Account,
};

/// A plugin's ledger: `pub const Ledger = publr.ledger.define(struct { ... }, .{ .reasons =
/// Reason, .units = Units })`.
pub fn define(comptime Accounts: type, comptime define_options: anytype) type {
    comptime check_accounts(Accounts);

    const Reason = define_options.reasons;
    const has_units = @hasField(@TypeOf(define_options), "units");
    const Units = if (has_units) define_options.units else struct {};

    comptime {
        if (@typeInfo(Reason) != .@"enum") {
            @compileError("a ledger's `.reasons` is an enum");
        }
    }

    return struct {
        pub const publr_ledger = true;
        pub const AccountsDeclared = Accounts;
        pub const Reasons = Reason;
        pub const UnitsDeclared = Units;
        pub const Name = std.meta.FieldEnum(Accounts);

        pub const Opening = struct {
            holder: Holder = .{},
            /// A word, when one name has many accounts tied to no record (`pl`, `label`).
            key: []const u8 = "",
            unit: UnitName,
        };

        pub const Transfer = struct {
            /// The plugin's own id: the same id again does nothing and answers the first.
            id: []const u8,
            debit: Account,
            credit: Account,
            amount: i64,
            reason: Reason,
            about: ?AnyRef = null,
            detail: ?AnyRef = null,
            happened_at: ?words.Time = null,
            /// Moves as much of the amount as the accounts' limits allow, possibly nothing.
            up_to: bool = false,
        };

        pub const Hold = struct {
            id: []const u8,
            debit: Account,
            credit: Account,
            amount: i64,
            reason: Reason,
            about: ?AnyRef = null,
            detail: ?AnyRef = null,
            happened_at: ?words.Time = null,
            up_to: bool = false,
            /// When core voids it, unless settled before.
            expires_at: ?words.Time = null,
        };

        pub const PostHold = struct {
            /// The hold, by the plugin's own id.
            hold: []const u8,
            /// Left out: all of it.
            amount: ?i64 = null,
        };

        pub const VoidHold = struct {
            hold: []const u8,
        };

        pub const Step = union(enum) {
            transfer: Transfer,
            hold: Hold,
            post_hold: PostHold,
            void_hold: VoidHold,
        };

        pub const Reversal = struct {
            id: []const u8,
            transfer: TransferRef,
            /// Left out: what is left of it.
            amount: ?i64 = null,
            reason: Reason,
        };

        pub const Conversion = struct {
            id: []const u8,
            from: Pair,
            to: Pair,
            amount: i64,
            rate: @import("decimal.zig").Decimal(model.rate_places),
            source: []const u8,
            reason: Reason,
            about: ?AnyRef = null,
            detail: ?AnyRef = null,
        };

        pub const Converted = struct {
            from: Done,
            to: Done,
        };

        /// The account of this name, holder, key and unit: opened on first use, the same one
        /// answered after.
        pub fn open(ctx: anytype, comptime name: Name, opening: Opening) Error!Account {
            std.debug.assert(opening.unit.base.len > 0);

            const unit_text = try unit_text_of(ctx, opening.unit);
            const holder = holder_of(opening.holder);
            const answered = try ctx.call(operations.Open, .{
                .name = @tagName(name),
                .holder_kind = holder.kind,
                .holder = holder.id,
                .key = opening.key,
                .unit = unit_text,
            });

            return .{
                .id = answered.account,
            };
        }

        pub fn transfer(ctx: anytype, given: Transfer) Error!Done {
            const answered = try ctx.call(operations.Transfer, step_of(given, .transfer));

            return done_of(answered);
        }

        pub fn hold(ctx: anytype, given: Hold) Error!Done {
            const answered = try ctx.call(operations.Hold, hold_step(given));

            return done_of(answered);
        }

        pub fn post_hold(ctx: anytype, given: PostHold) Error!Done {
            const answered = try ctx.call(operations.PostHold, .{
                .hold = given.hold,
                .amount = given.amount orelse 0,
            });

            return done_of(answered);
        }

        pub fn void_hold(ctx: anytype, given: VoidHold) Error!Done {
            const answered = try ctx.call(operations.VoidHold, .{
                .hold = given.hold,
            });

            return done_of(answered);
        }

        /// Steps posted whole or not at all, each seeing the ones before it.
        pub fn chain(ctx: anytype, steps: []const Step) Error![]const Done {
            const sent = try ctx.alloc(operations.Step, @intCast(steps.len));

            for (steps, sent) |step, *slot| {
                slot.* = switch (step) {
                    .transfer => |given| step_of(given, .transfer),
                    .hold => |given| hold_step(given),
                    .post_hold => |given| .{
                        .action = .post_hold,
                        .hold = given.hold,
                        .amount = given.amount orelse 0,
                    },
                    .void_hold => |given| .{
                        .action = .void_hold,
                        .hold = given.hold,
                    },
                };
            }

            const answered = try ctx.call(operations.Chain, .{
                .steps = sent,
            });
            const out = try ctx.alloc(Done, @intCast(answered.done.len));

            for (answered.done, out) |one, *slot| {
                slot.* = done_of(one);
            }

            std.debug.assert(out.len == steps.len);

            return out;
        }

        /// Undoes all or part of a posted transfer.
        pub fn reverse(ctx: anytype, given: Reversal) Error!Done {
            const answered = try ctx.call(operations.Reverse, .{
                .id = given.id,
                .transfer = given.transfer.id,
                .amount = given.amount orelse 0,
                .reason = @tagName(given.reason),
            });

            return done_of(answered);
        }

        /// Value from one unit to another, as two transfers in one chain.
        pub fn convert(ctx: anytype, given: Conversion) Error!Converted {
            const answered = try ctx.call(operations.Convert, .{
                .id = given.id,
                .from_debit = given.from.debit.id,
                .from_credit = given.from.credit.id,
                .to_debit = given.to.debit.id,
                .to_credit = given.to.credit.id,
                .amount = given.amount,
                .rate = given.rate.units,
                .source = given.source,
                .reason = @tagName(given.reason),
                .about = id_or_empty(given.about),
                .detail = id_or_empty(given.detail),
            });

            return .{
                .from = done_of(answered.from),
                .to = done_of(answered.to),
            };
        }

        pub fn close(ctx: anytype, account: Account) Error!void {
            _ = try ctx.call(operations.Close, .{
                .account = account.id,
            });
        }

        pub fn reopen(ctx: anytype, account: Account) Error!void {
            _ = try ctx.call(operations.Reopen, .{
                .account = account.id,
            });
        }

        /// One of the plugin's transfers by its own id.
        pub fn get(ctx: anytype, id: []const u8) Error!operations.Shown {
            std.debug.assert(id.len > 0);

            return ctx.call(operations.Get, .{
                .id = id,
            });
        }

        fn step_of(given: Transfer, comptime action: operations.StepAction) operations.Step {
            std.debug.assert(given.id.len > 0);

            return .{
                .action = action,
                .id = given.id,
                .debit = given.debit.id,
                .credit = given.credit.id,
                .amount = given.amount,
                .reason = @tagName(given.reason),
                .about = id_or_empty(given.about),
                .detail = id_or_empty(given.detail),
                .happened_at = if (given.happened_at) |at| at.ms else null,
                .up_to = given.up_to,
            };
        }

        fn hold_step(given: Hold) operations.Step {
            std.debug.assert(given.id.len > 0);

            return .{
                .action = .hold,
                .id = given.id,
                .debit = given.debit.id,
                .credit = given.credit.id,
                .amount = given.amount,
                .reason = @tagName(given.reason),
                .about = id_or_empty(given.about),
                .detail = id_or_empty(given.detail),
                .happened_at = if (given.happened_at) |at| at.ms else null,
                .up_to = given.up_to,
                .expires_at = if (given.expires_at) |at| at.ms else null,
            };
        }
    };
}

fn id_or_empty(ref: ?AnyRef) []const u8 {
    const given = ref orelse return "";

    std.debug.assert(given.id.len > 0);

    return given.id;
}

fn holder_of(holder: Holder) struct {
    kind: operations.HolderKind,
    id: []const u8,
} {
    std.debug.assert(holder.record == null or holder.person == null);

    if (holder.record) |record| {
        return .{
            .kind = .record,
            .id = record.id,
        };
    }

    if (holder.person) |person| {
        return .{
            .kind = .person,
            .id = person.id,
        };
    }

    return .{
        .kind = .none,
        .id = "",
    };
}

fn unit_text_of(ctx: anytype, given: UnitName) Error![]const u8 {
    std.debug.assert(given.base.len > 0);

    if (given.item.len == 0) {
        return given.base;
    }

    return ctx.print("{s}/{s}", .{ given.base, given.item });
}

fn done_of(answered: operations.Done) Done {
    std.debug.assert(answered.amount >= 0);

    return .{
        .transfer = if (answered.transfer.len > 0) .{
            .id = answered.transfer,
        } else null,
        .amount = answered.amount,
        .made = answered.made,
    };
}

fn check_accounts(comptime Accounts: type) void {
    comptime {
        if (@typeInfo(Accounts) != .@"struct") {
            @compileError("a ledger's accounts are the fields of a struct");
        }

        const info = @typeInfo(Accounts).@"struct";

        for (info.field_names, info.field_types) |field_name, Field| {
            if (!@hasDecl(Field, "ledger_kind")) {
                @compileError("ledger account `" ++ field_name ++ "`: give it a kind, " ++
                    "`publr.ledger.Liability(.{})` and the like");
            }
        }
    }
}

/// Whether `Ledger` is what `publr.ledger.define` makes.
pub fn is_ledger(comptime Ledger: type) bool {
    return @typeInfo(Ledger) == .@"struct" and @hasDecl(Ledger, "publr_ledger");
}

/// A bound plugin's ledger as core keeps it, its words from the plugin's doc comments; null
/// for a plugin with none.
pub fn declared_of(comptime Plugin: type) ?model.Declaration {
    comptime {
        if (!@hasField(@TypeOf(Plugin.options), "ledger")) {
            return null;
        }

        const Ledger = Plugin.options.ledger;
        const plugin = Plugin.manifest.name;

        if (!is_ledger(Ledger)) {
            @compileError("plugin " ++ plugin ++ ": `.ledger` is made with publr.ledger.define");
        }

        return .{
            .label = label_of(Plugin.docs, "ledger") orelse plugin,
            .description = plugin_define.rest(Plugin.docs, "ledger") orelse "",
            .accounts = accounts_of(Plugin, Ledger.AccountsDeclared),
            .reasons = reasons_of(Plugin, Ledger.Reasons),
            .units = units_of(Plugin, Ledger.UnitsDeclared),
        };
    }
}

fn label_of(comptime Docs: type, comptime key: []const u8) ?[]const u8 {
    comptime {
        const said = plugin_define.first(Docs, key) orelse return null;

        return @import("record_define.zig").label_of(said);
    }
}

fn accounts_of(comptime Plugin: type, comptime Accounts: type) []const model.DeclaredAccount {
    comptime {
        var list: []const model.DeclaredAccount = &.{};

        const info = @typeInfo(Accounts).@"struct";

        for (info.field_names, info.field_types) |field_name, Field| {
            const key = "ledger." ++ field_name;
            const label = label_of(Plugin.docs, key) orelse @compileError("plugin " ++
                Plugin.manifest.name ++ ": ledger account `" ++ field_name ++
                "` needs a `///`: its first line is its name in the admin");

            list = list ++ &[_]model.DeclaredAccount{.{
                .name = field_name,
                .label = label,
                .description = plugin_define.rest(Plugin.docs, key) orelse "",
                .kind = Field.ledger_kind,
                .limit = Field.ledger_limit,
            }};
        }

        return list;
    }
}

fn reasons_of(comptime Plugin: type, comptime Reason: type) []const model.DeclaredReason {
    comptime {
        var list: []const model.DeclaredReason = &.{};

        for (std.meta.fieldNames(Reason)) |name| {
            const key = @typeName(Reason) ++ "." ++ name;
            const label = label_of(Plugin.docs, key) orelse @compileError("plugin " ++
                Plugin.manifest.name ++ ": ledger reason `" ++ name ++ "` needs a `///`");

            list = list ++ &[_]model.DeclaredReason{.{
                .name = name,
                .label = label,
            }};
        }

        return list;
    }
}

fn units_of(comptime Plugin: type, comptime Units: type) []const model.DeclaredUnit {
    comptime {
        var list: []const model.DeclaredUnit = &.{};

        const info = @typeInfo(Units).@"struct";

        for (info.field_names, info.field_types) |field_name, Field| {
            const key = @typeName(Units) ++ "." ++ field_name;
            const label = label_of(Plugin.docs, key) orelse @compileError("plugin " ++
                Plugin.manifest.name ++ ": ledger unit `" ++ field_name ++ "` needs a `///`");
            const declared = Field.ledger_unit;

            list = list ++ &[_]model.DeclaredUnit{.{
                .name = field_name,
                .label = label,
                .scale = declared.scale,
                .symbol = declared.symbol,
            }};
        }

        return list;
    }
}

// The reads every plugin may make of accounts it may read (its own, those `ledger.read`
// names): `publr.ledger.balance(ctx, account)` and the rest.

pub const BalanceOptions = struct {
    /// The posted balance as it stood then.
    at: ?words.Time = null,
};

pub fn balance(ctx: anytype, account: Account) Error!operations.BalanceOut {
    return balance_at(ctx, account, .{});
}

pub fn balance_at(
    ctx: anytype,
    account: Account,
    given: BalanceOptions,
) Error!operations.BalanceOut {
    std.debug.assert(account.id.len > 0);

    return ctx.call(operations.Balance, .{
        .account = account.id,
        .at = if (given.at) |at| at.ms else null,
    });
}

pub const HistoryOptions = struct {
    about: ?AnyRef = null,
    from: ?words.Time = null,
    to: ?words.Time = null,
    /// The next page starts before the last transfer shown.
    before: ?TransferRef = null,
    limit: u32 = 50,
};

pub fn history(ctx: anytype, account: Account, given: HistoryOptions) Error!operations.HistoryOut {
    std.debug.assert(account.id.len > 0);

    return ctx.call(operations.History, .{
        .account = account.id,
        .about = id_or_empty(given.about),
        .from = if (given.from) |at| at.ms else null,
        .to = if (given.to) |at| at.ms else null,
        .before = if (given.before) |ref| ref.id else "",
        .limit = given.limit,
    });
}

/// What narrows a read of transfers; every part given must match. At least one of `about`,
/// `detail`, `account` and `name`.
pub const FindOptions = struct {
    about: ?AnyRef = null,
    detail: ?AnyRef = null,
    /// Only transfers of this reason: its name (`@tagName(Reason.payment)`).
    reason: []const u8 = "",
    account: ?Account = null,
    /// The accounts of one of the plugin's names.
    name: []const u8 = "",
};

/// How many transfers `find` reads at most, a page of 200 at a time; more is refused. A
/// read that shows a list asks `page`; one that needs a figure asks `totals`.
pub const find_max: u32 = 20_000;

/// Every transfer that matches, oldest first, on every account the plugin may read: an
/// order's money story. Read a page at a time, so core never holds more than one page; what
/// they add up to is `totals`, which reads none.
pub fn find(ctx: anytype, given: FindOptions) Error![]const operations.Shown {
    std.debug.assert(given.about != null or given.detail != null or given.account != null or
        given.name.len > 0);

    var all: std.ArrayList(operations.Shown) = .empty;
    var after: []const u8 = "";

    while (all.items.len < find_max) {
        const answered = try ctx.call(operations.Find, .{
            .about = id_or_empty(given.about),
            .detail = id_or_empty(given.detail),
            .reason = given.reason,
            .account = if (given.account) |account| account.id else "",
            .name = given.name,
            .after = after,
            .limit = @import("../operation.zig").page_limit_max,
        });

        if (after.len == 0 and answered.next.len == 0) {
            return answered.transfers;
        }

        all.appendSlice(ctx.arena(), answered.transfers) catch return error.OutOfMemory;
        after = answered.next;

        if (after.len == 0) {
            return all.items;
        }
    }

    return error.Invalid;
}

pub const PageOptions = struct {
    about: ?AnyRef = null,
    detail: ?AnyRef = null,
    /// Only transfers of this reason: its name (`@tagName(Reason.payment)`).
    reason: []const u8 = "",
    account: ?Account = null,
    /// The accounts of one of the plugin's names.
    name: []const u8 = "",
    /// The next page starts past the last transfer of the one before.
    after: ?TransferRef = null,
    /// 1 to 200.
    limit: u32 = 50,
    newest: bool = false,
};

pub const Page = struct {
    transfers: []const operations.Shown,
    /// What the next page takes as `after`; null after the last.
    after: ?TransferRef,
};

/// One page of the transfers that match, oldest first or `newest` first: what a list shows.
pub fn page(ctx: anytype, given: PageOptions) Error!Page {
    std.debug.assert(given.about != null or given.detail != null or given.account != null or
        given.name.len > 0);
    std.debug.assert(given.limit > 0);

    const answered = try ctx.call(operations.Find, .{
        .about = id_or_empty(given.about),
        .detail = id_or_empty(given.detail),
        .reason = given.reason,
        .account = if (given.account) |account| account.id else "",
        .name = given.name,
        .after = if (given.after) |ref| ref.id else "",
        .limit = given.limit,
        .newest = given.newest,
    });

    return .{
        .transfers = answered.transfers,
        .after = if (answered.next.len > 0) .{
            .id = answered.next,
        } else null,
    };
}

pub const TotalsOptions = struct {
    about: ?AnyRef = null,
    detail: ?AnyRef = null,
    /// Finer records by id, up to 200: one sum per detail, reason and unit, so a page of
    /// charges gets each one's figures in one read.
    details: []const []const u8 = &.{},
    /// Only transfers of this reason: its name.
    reason: []const u8 = "",
    account: ?Account = null,
    /// The accounts of one of the plugin's names.
    name: []const u8 = "",
    from: ?words.Time = null,
    to: ?words.Time = null,
};

/// Debits and credits, posted and pending, per reason and unit, over what matches: added up
/// in the database, no transfer read. A balance of the plugin's accounts of one name for a
/// record is `.{ .about = order, .name = "receivable" }`.
pub fn totals(ctx: anytype, given: TotalsOptions) Error![]const operations.Sum {
    std.debug.assert(given.details.len <= totals_max);

    var all: std.ArrayList(operations.Sum) = .empty;
    var after: []const u8 = "";

    // A page of sums a call; the sums one read may reach are bounded by `sums_max`.
    while (all.items.len < totals_max) {
        const answered = try ctx.call(operations.Totals, .{
            .about = id_or_empty(given.about),
            .detail = id_or_empty(given.detail),
            .details = given.details,
            .reason = given.reason,
            .account = if (given.account) |account| account.id else "",
            .name = given.name,
            .from = if (given.from) |at| at.ms else null,
            .to = if (given.to) |at| at.ms else null,
            .after = after,
        });

        if (after.len == 0 and answered.next.len == 0) {
            return answered.totals;
        }

        all.appendSlice(ctx.arena(), answered.totals) catch return error.OutOfMemory;
        after = answered.next;

        if (after.len == 0) {
            return all.items;
        }
    }

    return error.Invalid;
}

/// The most sums `totals` adds up across its pages.
const totals_max: u32 = 2000;

/// One transfer by its reference.
pub fn get(ctx: anytype, transfer: TransferRef) Error!operations.Shown {
    std.debug.assert(transfer.id.len > 0);

    return ctx.call(operations.Get, .{
        .transfer = transfer.id,
    });
}

pub const AccountsOptions = struct {
    owner: []const u8 = "",
    name: []const u8 = "",
    holder: ?AnyRef = null,
    unit: []const u8 = "",
    after: ?Account = null,
    limit: u32 = 50,
};

/// Accounts the plugin may read, a page at a time.
pub fn accounts(ctx: anytype, given: AccountsOptions) Error!operations.AccountsOut {
    return ctx.call(operations.Accounts, .{
        .plugin = given.owner,
        .name = given.name,
        .holder = id_or_empty(given.holder),
        .unit = given.unit,
        .after = if (given.after) |account| account.id else "",
        .limit = given.limit,
    });
}

/// One account the plugin may read: its name, kind, holder, unit and balances.
pub fn account_of(ctx: anytype, which: Account) Error!operations.Account.Out {
    std.debug.assert(which.id.len > 0);

    return ctx.call(operations.Account, .{
        .id = which.id,
    });
}
