//! The Settings area's door and its fixed first page: the system's own settings, and the
//! tabs plugins add to it. Users and the modeled sections have pages of their own.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const frame_pages = @import("frame/pages.zig");
const language_operations = @import("../../operations/user/language.zig");
const job_operations = @import("../../operations/job.zig");

const views = admin.views;
const page_path = "/admin/settings/system";

pub fn show(
    request: *admin.Request,
    response: *admin.Response,
    ctx: *admin.Context,
) admin.Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    _ = try admin.require(request, response, ctx) orelse return;

    try response.redirect(.see_other, page_path);
}

pub fn system(
    request: *admin.Request,
    response: *admin.Response,
    ctx: *admin.Context,
) admin.Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;

    try render(&session, .ok, .{
        .notice = if (admin.query_param(&session, "saved") != null)
            try session.translated("Saved.", .{})
        else
            "",
    });
}

/// `POST /admin/settings/system`: the language the admin speaks to whoever chose none, and
/// the site's time zone.
pub fn save(
    request: *admin.Request,
    response: *admin.Response,
    ctx: *admin.Context,
) admin.Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, page_path) orelse return;
    const session = &post.session;

    if (post.form.text("language")) |chosen| {
        const language = if (std.mem.eql(u8, chosen, "en")) "" else chosen;

        _ = registry.SDK.dispatch(&session.ctx, language_operations.SetSiteLanguage, .{
            .language = language,
        }) catch |err| return admin.fail(session, err, page_path);
    }

    if (post.form.text("time_zone")) |chosen| {
        _ = registry.SDK.dispatch(&session.ctx, job_operations.SetTimeZone, .{
            .time_zone = chosen,
        }) catch |err| return admin.fail(session, err, page_path);
    }

    try response.redirect(.see_other, page_path ++ "?saved=1");
}

/// Every time zone for the General tab, the site's selected.
fn time_zones_of(session: *admin.Session) admin.Error![]const views.SettingsSystem.Time_zonesItem {
    std.debug.assert(session.signed_in());

    const listed = registry.SDK.dispatch(&session.ctx, job_operations.List, .{}) catch {
        return &.{};
    };
    const names = try @import("../../lib/zone.zig").names(session.arena);
    const items = try session.arena.alloc(views.SettingsSystem.Time_zonesItem, names.len);

    for (names, items) |name, *item| {
        item.* = .{
            .name = name,
            .selected = std.mem.eql(u8, name, listed.time_zone),
        };
    }

    return items;
}

/// The admin's languages for the General tab, the site's default selected; none while it
/// speaks English alone.
fn languages_of(session: *admin.Session) admin.Error![]const views.SettingsSystem.LanguagesItem {
    std.debug.assert(session.signed_in());

    const shown = registry.SDK.dispatch(&session.ctx, language_operations.Language, .{}) catch {
        return &.{};
    };

    if (shown.choices.len < 2) {
        return &.{};
    }

    const items = try session.arena.alloc(views.SettingsSystem.LanguagesItem, shown.choices.len);
    const site = if (shown.site.len > 0) shown.site else "en";

    for (shown.choices, items) |choice, *item| {
        item.* = .{
            .locale = choice.locale,
            .label = choice.label,
            .selected = std.mem.eql(u8, choice.locale, site),
        };
    }

    return items;
}

const PluginTab = views.SettingsSystem.Plugin_tabsItem;

fn plugin_tabs_of(session: *admin.Session) admin.Error![]const PluginTab {
    std.debug.assert(session.signed_in());

    const all = try frame_pages.all(session);
    const found = try frame_pages.tabs_of(session.arena, all, frame_pages.system);
    const items = try session.arena.alloc(PluginTab, found.len);

    for (found, items) |page, *item| {
        item.* = .{
            .label = try session.declared(page.label),
            .href = try page.href(session.arena),
        };
    }

    return items;
}

const Shown = struct {
    notice: []const u8 = "",
};

fn render(session: *admin.Session, status: admin.Status, shown: Shown) admin.Error!void {
    std.debug.assert(shown.notice.len < 1024);
    std.debug.assert(session.signed_in());

    try admin.screen(session, status, views.SettingsSystem, .{
        .can_logs = registry.SDK.may(&session.ctx, @import("../../operations/activity.zig").List),
        .plugin_tabs = try plugin_tabs_of(session),
        .languages = try languages_of(session),
        .time_zones = try time_zones_of(session),
        .notice = shown.notice,
    }, .{});
}
