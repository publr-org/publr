//! The ledger in the admin, read only: a plugin's Ledger tab (its accounts), an account's
//! page (its totals and history, each transfer in a drawer), and Settings › Ledger (every
//! plugin's accounts, whether each unit's books balance, the full check). Everything is read
//! through the `ledger.*` operations; nobody types a transfer here.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const ledger = @import("../../operations/ledger.zig");
const plugin_operations = @import("../../operations/plugin.zig");
const shown = @import("ledger/shown.zig");

const views = admin.views;
const plugins_back = "/admin/settings/plugins";
const settings_path = "/admin/settings/ledger";
pub const account_path = "/admin/ledger/accounts";
const page_size: u32 = 50;

pub const routes_count: u32 = 3;

pub fn register(router: anytype) void {
    std.debug.assert(router.routes_len > 0);

    router.get(plugins_back ++ "/:name/ledger", &plugin_tab);
    router.get(account_path ++ "/:id", &account_page);
    router.get(settings_path, &settings_page);
}

/// Whether the plugin keeps a ledger: it declares one, or accounts of its stay from before.
pub fn has_ledger(session: *admin.Session, plugin: []const u8) bool {
    std.debug.assert(plugin.len > 0);

    if (registry.ledger_of(&session.ctx, plugin) != null) {
        return true;
    }

    const held = registry.SDK.dispatch(&session.ctx, ledger.Accounts, .{
        .plugin = plugin,
        .limit = 1,
    }) catch return false;

    return held.accounts.len > 0;
}

/// The Ledger tab's address, or empty for a plugin without a ledger.
pub fn tab_href(session: *admin.Session, plugin: []const u8) admin.Error![]const u8 {
    std.debug.assert(plugin.len > 0);

    if (!has_ledger(session, plugin)) {
        return "";
    }

    return std.fmt.allocPrint(session.arena, "{s}/{s}/ledger", .{ plugins_back, plugin });
}

const Filters = struct {
    name: []const u8,
    unit: []const u8,
    holder: []const u8,
    after: []const u8,
};

fn filters_of(session: *admin.Session) admin.Error!Filters {
    std.debug.assert(session.signed_in());

    const holder = admin.query_param(session, "holder") orelse "";

    return .{
        .name = admin.query_param(session, "name") orelse "",
        .unit = admin.query_param(session, "unit") orelse "",
        .holder = try shown.holder_id(session, holder),
        .after = admin.query_param(session, "after") orelse "",
    };
}

fn plugin_tab(
    request: *admin.Request,
    response: *admin.Response,
    ctx: *admin.Context,
) admin.Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const name = try admin.param(&session, "name", plugins_back) orelse return;
    const arena = session.arena;
    const detail = registry.SDK.dispatch(&session.ctx, plugin_operations.Get, .{
        .name = name,
    }) catch null;
    const filters = try filters_of(&session);
    const listed = registry.SDK.dispatch(&session.ctx, ledger.Accounts, .{
        .plugin = name,
        .name = filters.name,
        .unit = filters.unit,
        .holder = filters.holder,
        .after = filters.after,
        .limit = page_size,
    }) catch |err| return admin.fail(&session, err, plugins_back);
    const own = try std.fmt.allocPrint(arena, "{s}/{s}", .{ plugins_back, name });
    const here = try std.fmt.allocPrint(arena, "{s}/ledger", .{own});
    const gone = detail == null;

    try admin.screen(&session, .ok, views.PluginLedger, .{
        .name = name,
        .summary = if (detail) |found| found.summary else "",
        .gone = gone,
        .overview_href = if (gone) "" else own,
        .plugins_href = plugins_back,
        .log_href = if (gone) "" else try std.fmt.allocPrint(arena, "{s}/log", .{own}),
        .webhooks_href = if (@import("plugins/webhooks.zig").has_webhooks(&session, name))
            try std.fmt.allocPrint(arena, "{s}/webhooks", .{own})
        else
            "",
        .ledger_href = here,
        .names = try names_of(&session, name, filters.name),
        .unit = filters.unit,
        .holder = admin.query_param(&session, "holder") orelse "",
        .accounts = try shown.accounts(views.PluginLedger, &session, listed.accounts),
        .filtered = filters.name.len + filters.unit.len + filters.holder.len > 0,
        .next_href = try next_of(&session, here, listed.next),
    }, .{});
}

fn names_of(
    session: *admin.Session,
    plugin: []const u8,
    chosen: []const u8,
) admin.Error![]views.PluginLedger.NamesItem {
    std.debug.assert(plugin.len > 0);

    const declared = registry.ledger_of(&session.ctx, plugin) orelse return &.{};
    const names = try session.arena.alloc(views.PluginLedger.NamesItem, declared.accounts.len);

    for (declared.accounts, names) |account, *name| {
        name.* = .{
            .value = account.name,
            .label = account.label,
            .selected = std.mem.eql(u8, account.name, chosen),
        };
    }

    return names;
}

/// The next page: this one's filters, after the last account shown.
fn next_of(session: *admin.Session, path: []const u8, after: []const u8) admin.Error![]const u8 {
    std.debug.assert(path.len > 0);

    if (after.len == 0) {
        return "";
    }

    const query = session.request.query();
    const kept = if (std.mem.indexOf(u8, query, "after=")) |at| query[0..at] else query;
    const joiner: []const u8 = if (kept.len == 0 or std.mem.endsWith(u8, kept, "&")) "" else "&";

    return std.fmt.allocPrint(session.arena, "{s}?{s}{s}after={s}", .{
        path,
        kept,
        joiner,
        after,
    });
}

fn account_page(
    request: *admin.Request,
    response: *admin.Response,
    ctx: *admin.Context,
) admin.Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const id = try admin.param(&session, "id", settings_path) orelse return;
    const account = registry.SDK.dispatch(&session.ctx, ledger.Account, .{
        .id = id,
    }) catch |err| return admin.fail(&session, err, settings_path);
    const history = registry.SDK.dispatch(&session.ctx, ledger.History, .{
        .account = id,
        .before = admin.query_param(&session, "before") orelse "",
        .limit = page_size,
    }) catch |err| return admin.fail(&session, err, settings_path);
    const arena = session.arena;
    const here = try std.fmt.allocPrint(arena, "{s}/{s}", .{ account_path, id });
    var units: shown.Units = .{
        .session = &session,
        .unit = account.unit,
        .scale = account.scale,
        .owner = account.owner,
    };
    const holder = try shown.holder_of(&session, account.holder_kind, account.holder);

    try admin.screen(&session, .ok, views.LedgerAccount, .{
        .title = account.label,
        .plugin = account.owner,
        .ledger_href = try std.fmt.allocPrint(arena, "{s}/{s}/ledger", .{
            plugins_back,
            account.owner,
        }),
        .plugins_href = plugins_back,
        .kind = @tagName(account.kind),
        .limit = @tagName(account.limit),
        .holder = holder.title,
        .holder_href = holder.href,
        .key = account.key,
        .unit = account.unit,
        .closed = account.closed,
        .posted = try units.text(account.posted, false),
        .pending = try units.text(shown.held_of(account.pending), false),
        .available = try units.text(account.available, false),
        .debits_posted = try units.text(account.debits_posted, false),
        .credits_posted = try units.text(account.credits_posted, false),
        .debits_pending = try units.text(account.debits_pending, false),
        .credits_pending = try units.text(account.credits_pending, false),
        .lines = try shown.lines(&session, &units, history.lines),
        .older_href = if (history.before.len > 0)
            try std.fmt.allocPrint(arena, "{s}?before={s}", .{ here, history.before })
        else
            "",
    }, .{
        .settings_path = plugins_back,
    });
}

fn settings_page(
    request: *admin.Request,
    response: *admin.Response,
    ctx: *admin.Context,
) admin.Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const plugin = admin.query_param(&session, "plugin") orelse "";
    const filters = try filters_of(&session);
    const checked = registry.SDK.dispatch(&session.ctx, ledger.Check, .{}) catch |err| {
        return admin.fail(&session, err, "/admin/settings");
    };
    const listed = registry.SDK.dispatch(&session.ctx, ledger.Accounts, .{
        .plugin = plugin,
        .unit = filters.unit,
        .holder = filters.holder,
        .after = filters.after,
        .limit = page_size,
    }) catch |err| return admin.fail(&session, err, "/admin/settings");
    const ran = admin.query_param(&session, "check") != null;

    try admin.screen(&session, .ok, views.SettingsLedger, .{
        .ledger_href = settings_path,
        .check_href = settings_path ++ "?check=1",
        .units = try shown.unit_lines(&session, checked.units),
        .checked = if (!ran) "" else if (checked.in_balance) "ok" else "off",
        .differing = try std.fmt.allocPrint(session.arena, "{d}", .{checked.accounts.len}),
        .plugins = try plugins_of(&session, plugin),
        .unit = filters.unit,
        .holder = admin.query_param(&session, "holder") orelse "",
        .accounts = try shown.accounts(views.SettingsLedger, &session, listed.accounts),
        .filtered = plugin.len + filters.unit.len + filters.holder.len > 0,
        .next_href = try next_of(&session, settings_path, listed.next),
    }, .{});
}

/// Every plugin that declares a ledger, for the plugin filter.
fn plugins_of(
    session: *admin.Session,
    chosen: []const u8,
) admin.Error![]views.SettingsLedger.PluginsItem {
    std.debug.assert(session.signed_in());

    const owned = try registry.ledgers(&session.ctx, session.arena);
    const plugins = try session.arena.alloc(views.SettingsLedger.PluginsItem, owned.len);

    for (owned, plugins) |one, *plugin| {
        plugin.* = .{
            .value = one.owner,
            .selected = std.mem.eql(u8, one.owner, chosen),
        };
    }

    return plugins;
}
