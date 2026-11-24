//! The ledger's admin pages' rows: amounts written in their unit (a currency as the site
//! writes money, a declared unit at its scale with its symbol), holders and what transfers
//! are about by their titles, and each transfer's drawer.
const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const ledger = @import("../../../operations/ledger.zig");
const money = @import("../../../operations/money.zig");
const record = @import("../../../operations/record.zig");
const user = @import("../../../operations/user.zig");
const model = @import("../../../model/ledger.zig");
const activity_page = @import("../activity.zig");

const views = admin.views;
const account_path = "/admin/ledger/accounts";

/// Writes amounts of one unit.
pub const Units = struct {
    session: *admin.Session,
    unit: []const u8,
    scale: u8,
    /// The plugin keeping the account: its ledger says a declared unit's symbol.
    owner: []const u8,

    /// `amount` as people read it; `signed` puts `+` before a positive one.
    pub fn text(units: *Units, amount: i64, signed: bool) admin.Error![]const u8 {
        std.debug.assert(units.unit.len > 0);

        const arena = units.session.arena;
        const sign: []const u8 = if (signed and amount > 0) "+" else "";
        const base = if (std.mem.indexOfScalar(u8, units.unit, '/')) |at|
            units.unit[0..at]
        else
            units.unit;

        if (model.currency_scale(base) != null) {
            const written = registry.SDK.dispatch(&units.session.ctx, money.Text, .{
                .amount = try @import("../../../sdk/money.zig").Money.of(arena, base, amount),
            }) catch null;

            if (written) |found| {
                if (found.text.len > 0) {
                    return std.fmt.allocPrint(arena, "{s}{s}", .{ sign, found.text });
                }
            }
        }

        var buffer: [48]u8 = undefined;
        const number = model.written(&buffer, amount, units.scale);

        return std.fmt.allocPrint(arena, "{s}{s} {s}", .{ sign, number, symbol_of(units, base) });
    }

    fn symbol_of(units: *const Units, base: []const u8) []const u8 {
        std.debug.assert(base.len > 0);

        const parts = model.declared_parts(base) orelse return base;
        const declared = registry.ledger_of(&units.session.ctx, parts[0]) orelse return base;
        const unit = declared.unit(parts[1]) orelse return base;

        return if (unit.symbol.len > 0) unit.symbol else unit.label;
    }
};

pub const Linked = struct {
    title: []const u8,
    href: []const u8,
};

/// A holder by its title and page: a record's, or a person's name; the id when neither reads.
pub fn holder_of(
    session: *admin.Session,
    kind: []const u8,
    id: []const u8,
) admin.Error!Linked {
    std.debug.assert(kind.len <= 16);

    if (id.len == 0) {
        return .{
            .title = "",
            .href = "",
        };
    }

    if (std.mem.eql(u8, kind, "person")) {
        const found = registry.SDK.dispatch(&session.ctx, user.Get, .{
            .user = id,
        }) catch return .{
            .title = id,
            .href = "",
        };

        return .{
            .title = found.user.display_name,
            .href = try std.fmt.allocPrint(session.arena, "/admin/settings/users/{s}", .{id}),
        };
    }

    return record_of(session, id);
}

/// A record by its title and its page in Content; its id alone when it is none (an internal
/// record) or the person may not read it.
pub fn record_of(session: *admin.Session, id: []const u8) admin.Error!Linked {
    std.debug.assert(session.signed_in());

    if (id.len == 0) {
        return .{
            .title = "",
            .href = "",
        };
    }

    const titles = registry.SDK.dispatch(&session.ctx, record.Shown, .{
        .ids = &.{id},
    }) catch return .{
        .title = id,
        .href = "",
    };

    if (titles.titles.len == 0) {
        return .{
            .title = id,
            .href = "",
        };
    }

    return .{
        .title = titles.titles[0].title,
        .href = try std.fmt.allocPrint(session.arena, "/admin/content/{s}", .{id}),
    };
}

/// What the holder search names: a person by email or id when there is one, else the text as
/// a record's id.
pub fn holder_id(session: *admin.Session, given: []const u8) admin.Error![]const u8 {
    std.debug.assert(given.len <= 1 << 16);

    const trimmed = std.mem.trim(u8, given, " ");

    if (trimmed.len == 0) {
        return "";
    }

    const found = registry.SDK.dispatch(&session.ctx, user.Get, .{
        .user = trimmed,
    }) catch return trimmed;

    return found.user.id;
}

/// Accounts as `View`'s list draws them.
pub fn accounts(
    comptime View: type,
    session: *admin.Session,
    listed: []const ledger.AccountView,
) admin.Error![]@typeInfo(@FieldType(View.Props, "accounts")).pointer.child {
    const Item = @typeInfo(@FieldType(View.Props, "accounts")).pointer.child;
    const rows = try session.arena.alloc(Item, listed.len);

    std.debug.assert(listed.len <= 200);

    for (listed, rows) |account, *row| {
        var units: Units = .{
            .session = session,
            .unit = account.unit,
            .scale = account.scale,
            .owner = account.owner,
        };
        const holder = try holder_of(session, account.holder_kind, account.holder);

        row.* = .{
            .href = try std.fmt.allocPrint(session.arena, "{s}/{s}", .{
                account_path,
                account.account,
            }),
            .label = account.label,
            .plugin = account.owner,
            .holder = if (holder.title.len > 0) holder.title else account.key,
            .holder_href = holder.href,
            .unit = account.unit,
            .balance = try units.text(account.posted, false),
            .held = try units.text(held_of(account.pending), false),
            .available = try units.text(account.available, false),
            .closed = account.closed,
        };
    }

    return rows;
}

/// What holds keep, whichever way they go.
pub fn held_of(pending: i64) i64 {
    std.debug.assert(pending > std.math.minInt(i64));

    return if (pending < 0) -pending else pending;
}

/// Each unit's books: in balance, or the difference written in the unit.
pub fn unit_lines(
    session: *admin.Session,
    sums: []const ledger.UnitLine,
) admin.Error![]views.SettingsLedger.UnitsItem {
    const items = try session.arena.alloc(views.SettingsLedger.UnitsItem, sums.len);

    std.debug.assert(items.len == sums.len);

    for (sums, items) |line, *item| {
        var units: Units = .{
            .session = session,
            .unit = line.unit,
            .scale = 0,
            .owner = "",
        };

        item.* = .{
            .unit = line.unit,
            .in_balance = line.in_balance,
            .difference = try units.text(line.difference, false),
        };
    }

    return items;
}

const Line = views.LedgerAccount.LinesItem;
const Detail = @typeInfo(@FieldType(Line, "details")).pointer.child;

/// An account's history as its page draws it, each transfer with its drawer's facts.
pub fn lines(
    session: *admin.Session,
    units: *Units,
    listed: []const ledger.Line,
) admin.Error![]Line {
    const items = try session.arena.alloc(Line, listed.len);

    std.debug.assert(listed.len <= 200);

    for (listed, items) |line, *item| {
        const when = try activity_page.when_of(session.arena, line.happened_at);
        const other_label = @import("../../../operations/ledger/declared.zig").account_label(
            &session.ctx,
            line.other_owner,
            line.other_name,
        );
        const about = try record_of(session, line.about);

        item.* = .{
            .date = when.date,
            .time = when.time,
            .reason = line.reason_label,
            .other = other_label,
            .other_plugin = line.other_owner,
            .other_href = try std.fmt.allocPrint(session.arena, "{s}/{s}", .{
                account_path,
                line.other,
            }),
            .amount = try units.text(line.amount, true),
            .grows = line.amount > 0,
            .balance_after = try units.text(line.balance_after, false),
            .status = @tagName(line.status),
            .about = about.title,
            .about_href = about.href,
            .details = try details_of(session, units, line.transfer),
        };
    }

    return items;
}

/// Everything a transfer holds, for its drawer: read whole with `ledger.get`.
fn details_of(session: *admin.Session, units: *Units, id: []const u8) admin.Error![]Detail {
    std.debug.assert(id.len > 0);

    const transfer = registry.SDK.dispatch(&session.ctx, ledger.Get, .{
        .transfer = id,
    }) catch return &.{};
    var list: std.ArrayList(Detail) = .empty;
    var facts: Facts = .{
        .session = session,
        .list = &list,
    };

    try facts.add("Transfer", transfer.transfer, "");
    try facts.add("Amount", try units.text(transfer.amount, false), "");
    try facts.add("Reason", transfer.reason_label, "");
    try facts.add("Made by", transfer.maker, "");
    try facts.add("Its id", transfer.maker_id, "");
    try facts.add("Made for", transfer.made_for, "");
    try facts.add("Author", transfer.author, "");
    const debit = try account_text(transfer.debit_owner, transfer.debit_name, session);
    const credit = try account_text(transfer.credit_owner, transfer.credit_name, session);

    try facts.add("Debit account", debit, try account_href(session, transfer.debit));
    try facts.add("Credit account", credit, try account_href(session, transfer.credit));
    try facts.more(transfer);

    return list.items;
}

fn account_text(
    owner: []const u8,
    name: []const u8,
    session: *admin.Session,
) admin.Error![]const u8 {
    std.debug.assert(name.len > 0);

    const label = @import("../../../operations/ledger/declared.zig").account_label(
        &session.ctx,
        owner,
        name,
    );

    return std.fmt.allocPrint(session.arena, "{s} · {s}", .{ label, owner });
}

fn account_href(session: *admin.Session, id: []const u8) admin.Error![]const u8 {
    std.debug.assert(id.len > 0);

    return std.fmt.allocPrint(session.arena, "{s}/{s}", .{ account_path, id });
}

const Facts = struct {
    session: *admin.Session,
    list: *std.ArrayList(Detail),

    /// One fact, its label in the person's language; none when it holds nothing.
    fn add(
        facts: *Facts,
        comptime label: []const u8,
        value: []const u8,
        href: []const u8,
    ) admin.Error!void {
        std.debug.assert(label.len > 0);

        if (value.len == 0) {
            return;
        }

        try facts.list.append(facts.session.arena, .{
            .label = try facts.session.translated(label, .{}),
            .value = value,
            .href = href,
        });
    }

    /// The links a transfer may have: its chain, a hold it settles or what settled it, its
    /// reversals, a conversion's rate and other leg, when it happened and was posted.
    fn more(facts: *Facts, transfer: ledger.Shown) admin.Error!void {
        const arena = facts.session.arena;

        std.debug.assert(transfer.transfer.len > 0);

        if (!std.mem.eql(u8, transfer.chain, transfer.transfer)) {
            try facts.add("Posted together with", transfer.chain, "");
        }

        try facts.add("Settles the hold", transfer.hold, "");
        try facts.add("Settled by", transfer.settled_by, "");
        try facts.add("Reverses", transfer.reverses, "");

        for (transfer.reversals) |reversal| {
            try facts.add("Reversed by", reversal, "");
        }

        if (transfer.rate > 0) {
            var buffer: [48]u8 = undefined;
            const rate = model.written(&buffer, transfer.rate, model.rate_places);

            try facts.add("Rate", try arena.dupe(u8, rate), "");
            try facts.add("Rate from", transfer.source, "");
            try facts.add("Other leg", transfer.pair, "");
        }

        const happened = try activity_page.when_of(arena, transfer.happened_at);
        const posted = try activity_page.when_of(arena, transfer.posted_at);

        try facts.add("Happened", try std.fmt.allocPrint(arena, "{s} {s}", .{
            happened.date,
            happened.time,
        }), "");
        try facts.add("Posted", try std.fmt.allocPrint(arena, "{s} {s}", .{
            posted.date,
            posted.time,
        }), "");
    }
};
