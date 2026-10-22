//! A plugin's Webhooks tab: the address of each of its webhooks to paste into the sender's
//! settings, and what was sent, newest first, each delivery whose signature held with Run
//! again.

const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const activity_page = @import("../activity.zig");
const definitions = @import("../definitions.zig");
const plugin_operations = @import("../../../operations/plugin.zig");
const webhook = @import("../../../operations/webhook.zig");

const views = admin.views;
const back = "/admin/settings/plugins";

/// Whether the plugin declares a webhook: its page then has the tab.
pub fn has_webhooks(session: *admin.Session, plugin: []const u8) bool {
    std.debug.assert(plugin.len > 0);

    for (registry.webhook_owners) |owner| {
        if (std.mem.eql(u8, owner, plugin)) {
            return true;
        }
    }

    const sandboxed = session.ctx.sandboxed_plugins orelse return false;

    for (sandboxed.manifests()) |manifest| {
        if (std.mem.eql(u8, manifest.name, plugin)) {
            return manifest.webhooks.len > 0;
        }
    }

    return false;
}

pub fn show(
    request: *admin.Request,
    response: *admin.Response,
    ctx: *admin.Context,
) admin.Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const done = admin.query_param(&session, "done") orelse "";
    const notice = if (std.mem.eql(u8, done, "again"))
        try session.translated("Queued to run again now.", .{})
    else
        "";

    try screen(&session, notice, "");
}

fn screen(session: *admin.Session, notice: []const u8, problem: []const u8) admin.Error!void {
    std.debug.assert(session.signed_in());
    std.debug.assert(notice.len == 0 or problem.len == 0);

    const name = try admin.param(session, "name", back) orelse return;
    const detail = registry.SDK.dispatch(&session.ctx, plugin_operations.Get, .{
        .name = name,
    }) catch |err| return admin.fail(session, err, back);
    const listed = registry.SDK.dispatch(&session.ctx, webhook.List, .{
        .plugin = name,
    }) catch |err| return admin.fail(session, err, back);
    const arena = session.arena;
    const site = try definitions.host_url_of(session);
    const own = try std.fmt.allocPrint(arena, "{s}/{s}", .{ back, name });
    const addresses = try arena.alloc(views.PluginWebhooks.WebhooksItem, listed.webhooks.len);
    const deliveries = try arena.alloc(
        views.PluginWebhooks.DeliveriesItem,
        listed.deliveries.len,
    );

    for (listed.webhooks, addresses) |item, *address| {
        address.* = .{
            .name = item.name,
            .url = try std.fmt.allocPrint(arena, "{s}{s}", .{ site, item.path }),
        };
    }

    for (listed.deliveries, deliveries) |item, *delivery| {
        const when = try activity_page.when_of(arena, item.received_at);

        delivery.* = .{
            .name = item.name,
            .date = when.date,
            .time = when.time,
            .sender = item.sender,
            .verified = item.verified,
            .result = item.result,
            .problem = item.problem,
            .lines = item.lines,
            .run_action = if (item.verified)
                try std.fmt.allocPrint(arena, "{s}/webhooks/{d}/run", .{ own, item.id })
            else
                "",
        };
    }

    try admin.screen(session, .ok, views.PluginWebhooks, .{
        .name = name,
        .summary = detail.summary,
        .overview_href = own,
        .plugins_href = if (detail.mode == .native) back ++ "/built-in" else back,
        .log_href = try std.fmt.allocPrint(arena, "{s}/log", .{own}),
        .webhooks_href = try std.fmt.allocPrint(arena, "{s}/webhooks", .{own}),
        .webhooks = addresses,
        .deliveries = deliveries,
        .notice = notice,
        .problem = problem,
    }, .{});
}

pub fn run_again(
    request: *admin.Request,
    response: *admin.Response,
    ctx: *admin.Context,
) admin.Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const name = try admin.param(session, "name", back) orelse return;
    const id_text = try admin.param(session, "id", back) orelse return;

    _ = registry.SDK.dispatch(&session.ctx, webhook.RunAgain, .{
        .delivery = std.fmt.parseInt(i64, id_text, 10) catch 0,
    }) catch |err| {
        const failure = if (err == error.Failed) session.ctx.failure else null;

        return screen(session, "", if (failure) |found| found.message else @errorName(err));
    };

    const tab = try std.fmt.allocPrint(session.arena, "{s}/{s}/webhooks?done=again", .{
        back,
        name,
    });

    try response.redirect(.see_other, tab);
}
