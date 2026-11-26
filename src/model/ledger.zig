//! The double-entry ledger's arithmetic, after TigerBeetle: an account's four totals, the side
//! its balance grows on, the limit it keeps, and a unit's smallest step. Pure: the engine in
//! `operations/ledger/` reads and writes the rows, this says what they mean.
const std = @import("std");
const currency = @import("currency.zig");

pub const Kind = @import("../publr/model/ledger.zig").Kind;

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

/// What a transfer row is.
pub const Action = enum {
    /// Posted at once.
    transfer,
    /// A hold: pending until settled.
    hold,
    /// Posts a hold, all or part.
    post,
    /// Releases a hold.
    void,
    /// Releases a hold at its expiry.
    expire,
    /// Undoes a posted transfer, all or part.
    reverse,
    /// One leg of a conversion.
    convert,

    /// Whether its amount lands in the posted totals.
    pub fn posts(action: Action) bool {
        return action != .hold and action != .void and action != .expire;
    }
};

pub const Totals = struct {
    debits_posted: i64 = 0,
    credits_posted: i64 = 0,
    debits_pending: i64 = 0,
    credits_pending: i64 = 0,
};

/// The posted balance, on the side the kind grows on.
pub fn posted(kind: Kind, totals: Totals) i64 {
    std.debug.assert(totals.debits_posted >= 0 and totals.credits_posted >= 0);
    std.debug.assert(totals.debits_pending >= 0 and totals.credits_pending >= 0);

    const debit_side = @as(i128, totals.debits_posted) - totals.credits_posted;

    return clamp(if (kind.grows_by_debit()) debit_side else -debit_side);
}

/// The holds on the account, net, on the side the kind grows on.
pub fn pending(kind: Kind, totals: Totals) i64 {
    std.debug.assert(totals.debits_pending >= 0 and totals.credits_pending >= 0);

    const debit_side = @as(i128, totals.debits_pending) - totals.credits_pending;

    return clamp(if (kind.grows_by_debit()) debit_side else -debit_side);
}

/// The balance once every hold against it posts.
pub fn available(kind: Kind, totals: Totals) i64 {
    const sum = @as(i128, posted(kind, totals)) + pending(kind, totals);

    std.debug.assert(sum >= std.math.minInt(i64) * 2);

    return clamp(sum);
}

fn clamp(value: i128) i64 {
    std.debug.assert(value > std.math.minInt(i128) / 2);

    return @intCast(std.math.clamp(value, std.math.minInt(i64), std.math.maxInt(i64)));
}

pub const Side = enum { debit, credit };

/// How much more may land on `side` of the account, holds counted (TigerBeetle's
/// `debits_must_not_exceed_credits` and its mirror); null when its limit leaves it open.
pub fn headroom(kind: Kind, limit: Limit, totals: Totals, side: Side) ?i64 {
    std.debug.assert(totals.debits_posted >= 0 and totals.credits_pending >= 0);

    if (limit == .none) {
        return null;
    }

    // Below zero on a debit-grown account is more credits than debits, and so on.
    const debits_capped = (limit == .never_below_zero) != kind.grows_by_debit();
    const capped: Side = if (debits_capped) .debit else .credit;

    if (side != capped) {
        return null;
    }

    const room: i128 = if (capped == .debit)
        @as(i128, totals.credits_posted) - totals.debits_posted - totals.debits_pending
    else
        @as(i128, totals.debits_posted) - totals.credits_posted - totals.credits_pending;

    return clamp(@max(room, 0));
}

/// `total + amount`, or null past what 64 bits hold.
pub fn added(total: i64, amount: i64) ?i64 {
    std.debug.assert(total >= 0);
    std.debug.assert(amount >= 0);

    return std.math.add(i64, total, amount) catch null;
}

/// A unit as written: a currency (`PLN`), a declared unit (`loyalty.points`), either counted
/// per record (`inventory.pcs/<id>`).
pub const Unit = struct {
    base: []const u8,
    item: []const u8 = "",
};

pub const unit_len_max: u32 = 128;
pub const id_len_max: u32 = 128;
pub const name_len_max: u32 = 48;

pub fn unit_of(text: []const u8) ?Unit {
    std.debug.assert(unit_len_max > 0);

    if (text.len == 0 or text.len > unit_len_max) {
        return null;
    }

    const slash = std.mem.indexOfScalar(u8, text, '/');
    const base = if (slash) |at| text[0..at] else text;
    const item = if (slash) |at| text[at + 1 ..] else "";

    if (base.len == 0 or (slash != null and item.len == 0) or !word_like(base, true)) {
        return null;
    }

    return .{
        .base = base,
        .item = item,
    };
}

/// The base's plugin and unit name when it is a declared unit (`loyalty.points`); null for a
/// currency.
pub fn declared_parts(base: []const u8) ?[2][]const u8 {
    std.debug.assert(base.len > 0);

    const dot = std.mem.indexOfScalar(u8, base, '.') orelse return null;

    if (dot == 0 or dot + 1 == base.len) {
        return null;
    }

    return .{ base[0..dot], base[dot + 1 ..] };
}

/// A currency's scale from the ISO 4217 table; null for anything that is not one.
pub fn currency_scale(base: []const u8) ?u8 {
    std.debug.assert(base.len > 0);

    if (declared_parts(base) != null) {
        return null;
    }

    const found = currency.find(base) orelse return null;

    return found.digits;
}

/// Letters, digits and `_` (and one `.` when `dotted`): a name, a reason, a key.
pub fn word_like(text: []const u8, dotted: bool) bool {
    std.debug.assert(text.len <= 1 << 20);

    if (text.len == 0 or text.len > unit_len_max) {
        return false;
    }

    for (text) |byte| {
        const fine = std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or
            (dotted and byte == '.');

        if (!fine) {
            return false;
        }
    }

    return true;
}

/// The places a conversion's rate keeps.
pub const rate_places: u8 = 6;

/// `amount` of a unit of `from_scale` at `rate` (units of `rate_places`), in a unit of
/// `to_scale`: rounded down, in favour of the exchange account; null past 64 bits.
pub fn converted(amount: i64, rate_units: i64, from_scale: u8, to_scale: u8) ?i64 {
    std.debug.assert(amount > 0);
    std.debug.assert(rate_units > 0);

    const places: i32 = @as(i32, to_scale) - from_scale - rate_places;
    var value: i128 = @as(i128, amount) * rate_units;

    if (places >= 0) {
        value *= std.math.powi(i128, 10, @intCast(places)) catch return null;
    } else {
        value = @divFloor(value, std.math.powi(i128, 10, @intCast(-places)) catch return null);
    }

    if (value > std.math.maxInt(i64)) {
        return null;
    }

    return @intCast(value);
}

/// A plugin's ledger as it declares it (`publr.ledger.define`): its accounts' names, kinds
/// and limits, its reasons and its units, each with the words of its doc comment.
pub const Declaration = struct {
    label: []const u8 = "",
    description: []const u8 = "",
    accounts: []const DeclaredAccount = &.{},
    reasons: []const DeclaredReason = &.{},
    units: []const DeclaredUnit = &.{},

    pub fn account(declaration: Declaration, name: []const u8) ?DeclaredAccount {
        std.debug.assert(declaration.accounts.len <= declared_max);

        for (declaration.accounts) |each| {
            if (std.mem.eql(u8, each.name, name)) {
                return each;
            }
        }

        return null;
    }

    pub fn reason(declaration: Declaration, name: []const u8) ?DeclaredReason {
        std.debug.assert(declaration.reasons.len <= declared_max);

        for (declaration.reasons) |each| {
            if (std.mem.eql(u8, each.name, name)) {
                return each;
            }
        }

        return null;
    }

    pub fn unit(declaration: Declaration, name: []const u8) ?DeclaredUnit {
        std.debug.assert(declaration.units.len <= declared_max);

        for (declaration.units) |each| {
            if (std.mem.eql(u8, each.name, name)) {
                return each;
            }
        }

        return null;
    }
};

/// Names, reasons or units one ledger declares at most.
pub const declared_max: u32 = 256;

pub const DeclaredAccount = struct {
    name: []const u8,
    label: []const u8,
    description: []const u8 = "",
    kind: Kind,
    limit: Limit = .none,
};

pub const DeclaredReason = struct {
    name: []const u8,
    label: []const u8,
};

pub const DeclaredUnit = struct {
    name: []const u8,
    label: []const u8,
    /// Decimal places of its smallest step: points 0, kg 3.
    scale: u8,
    symbol: []const u8 = "",
};

/// Why a declaration cannot be a ledger, or null.
pub fn declaration_problem(declaration: Declaration) ?[]const u8 {
    std.debug.assert(declared_max > 0);

    const too_many = declaration.accounts.len > declared_max or
        declaration.reasons.len > declared_max or declaration.units.len > declared_max;

    if (too_many) {
        return "a ledger declares at most 256 accounts, reasons and units";
    }

    for (declaration.accounts) |each| {
        if (!word_like(each.name, false) or each.name.len > name_len_max) {
            return "an account's name is a word of letters, digits and _";
        }
    }

    for (declaration.units) |each| {
        if (!word_like(each.name, false) or each.scale > 18) {
            return "a unit's name is a word, its scale at most 18";
        }
    }

    return null;
}

/// A refusal of the ledger's, in core's words.
pub const Refusal = struct {
    name: []const u8,
    status: u16,
    message: []const u8,
};

pub const refusals = struct {
    pub const not_yours: Refusal = .{
        .name = "NotYours",
        .status = 403,
        .message = "This account is another plugin's; only its owner moves it",
    };
    pub const no_account: Refusal = .{
        .name = "NoAccount",
        .status = 404,
        .message = "There is no such ledger account",
    };
    pub const closed: Refusal = .{
        .name = "Closed",
        .status = 409,
        .message = "This account is closed",
    };
    pub const unit_mismatch: Refusal = .{
        .name = "UnitMismatch",
        .status = 409,
        .message = "The two accounts count different units",
    };
    pub const unbalanced: Refusal = .{
        .name = "Unbalanced",
        .status = 400,
        .message = "A transfer moves a positive amount between two different accounts",
    };
    pub const overdrawn: Refusal = .{
        .name = "Overdrawn",
        .status = 409,
        .message = "This would break an account's limit",
    };
    pub const taken: Refusal = .{
        .name = "Taken",
        .status = 409,
        .message = "This id made a different transfer",
    };
    pub const no_hold: Refusal = .{
        .name = "NoHold",
        .status = 404,
        .message = "There is no such hold",
    };
    pub const over_hold: Refusal = .{
        .name = "OverHold",
        .status = 409,
        .message = "A hold posts for its amount or less",
    };
    pub const settled: Refusal = .{
        .name = "Settled",
        .status = 409,
        .message = "This hold is settled already",
    };
    pub const expired: Refusal = .{
        .name = "Expired",
        .status = 409,
        .message = "This hold expired",
    };
    pub const over_reversed: Refusal = .{
        .name = "OverReversed",
        .status = 409,
        .message = "More than is left of the transfer to reverse",
    };
    pub const too_large: Refusal = .{
        .name = "TooLarge",
        .status = 409,
        .message = "A total would pass what the ledger holds",
    };
};

test "balances read on the side the kind grows on" {
    const totals: Totals = .{
        .debits_posted = 500,
        .credits_posted = 200,
        .debits_pending = 50,
        .credits_pending = 10,
    };

    try std.testing.expectEqual(@as(i64, 300), posted(.asset, totals));
    try std.testing.expectEqual(@as(i64, -300), posted(.liability, totals));
    try std.testing.expectEqual(@as(i64, 40), pending(.asset, totals));
    try std.testing.expectEqual(@as(i64, 340), available(.asset, totals));
}

test "a limit caps one side, holds counted" {
    const held: Totals = .{
        .credits_posted = 1000,
        .debits_pending = 300,
    };

    // Points held (a liability) never below zero: debits may take 700 more.
    const below: Limit = .never_below_zero;

    try std.testing.expectEqual(@as(?i64, 700), headroom(.liability, below, held, .debit));
    try std.testing.expectEqual(@as(?i64, null), headroom(.liability, below, held, .credit));
    try std.testing.expectEqual(@as(?i64, null), headroom(.liability, .none, held, .debit));
    try std.testing.expectEqual(@as(?i64, 700), headroom(.asset, .never_above_zero, held, .debit));
}

test "units: currencies, declared units, per item; conversions round down" {
    try std.testing.expectEqual(@as(?u8, 2), currency_scale("PLN"));
    try std.testing.expectEqual(@as(?u8, 0), currency_scale("JPY"));
    try std.testing.expectEqual(@as(?u8, null), currency_scale("loyalty.points"));
    try std.testing.expectEqualStrings("abc", unit_of("inventory.pcs/abc").?.item);
    try std.testing.expect(unit_of("inventory.pcs/") == null);
    try std.testing.expect(unit_of("") == null);
    // 100.00 EUR at 4.2817 is 428.17 PLN; 0.01 at 4.2817 is 0.04.
    try std.testing.expectEqual(@as(?i64, 42817), converted(10000, 4_281_700, 2, 2));
    try std.testing.expectEqual(@as(?i64, 4), converted(1, 4_281_700, 2, 2));
    // 1,000 points at 0.01 PLN a point: 10.00 PLN.
    try std.testing.expectEqual(@as(?i64, 1000), converted(1000, 10_000, 0, 2));
    try std.testing.expectEqual(@as(?i64, null), added(std.math.maxInt(i64), 1));
}

/// An amount in a unit's smallest step as people write it: 1250 at scale 2 is `12.50`, at 0
/// `1250`, -5 at 3 `-0.005`.
pub fn written(buffer: *[48]u8, amount: i64, scale: u8) []const u8 {
    std.debug.assert(scale <= 18);
    std.debug.assert(buffer.len >= 48);

    const step = std.math.powi(u64, 10, scale) catch unreachable;
    const magnitude = @abs(amount);
    const sign: []const u8 = if (amount < 0) "-" else "";
    const whole = magnitude / step;
    const fraction = magnitude % step;
    const text = if (scale == 0)
        std.fmt.bufPrint(buffer, "{s}{d}", .{ sign, whole })
    else
        std.fmt.bufPrint(buffer, "{s}{d}.{d:0>[3]}", .{ sign, whole, fraction, scale });

    return text catch buffer[0..0];
}

test "amounts written at their unit's scale" {
    var buffer: [48]u8 = undefined;

    try std.testing.expectEqualStrings("12.50", written(&buffer, 1250, 2));
    try std.testing.expectEqualStrings("1250", written(&buffer, 1250, 0));
    try std.testing.expectEqualStrings("-0.005", written(&buffer, -5, 3));
}
