//! Installed plugins in the admin, under Settings: one list of every plugin added, running or
//! not; the review before enabling one or applying its update; and a plugin's own page,
//! where each permission is granted or taken back one at a time and a version rolled back.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const plugin_operations = @import("../../operations/plugin.zig");
const settings_nav = @import("settings_nav.zig");
const rows = @import("plugins/rows.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const Session = admin.Session;
const views = admin.views;

pub const back = "/admin/settings/plugins";

pub fn register(router: anytype) void {
    std.debug.assert(router.routes_len > 0);

    router.get(back, &list);
    router.get(back ++ "/built-in", &built_in);
    router.get(back ++ "/:name", &show);
    router.get(back ++ "/:name/enable", &review_enable);
    router.post(back ++ "/:name/enable", &enable);
    router.post(back ++ "/:name/disable", &disable);
    router.get(back ++ "/:name/update", &review_update);
    router.post(back ++ "/:name/update", &update);
    router.post(back ++ "/:name/cancel-update", &cancel_update);
    router.post(back ++ "/:name/rollback", &rollback);
    router.post(back ++ "/:name/decide", &decide);
    router.post(back ++ "/:name/access", &access);
    router.post(back ++ "/:name/remove", &remove);
}

pub fn list(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const listed = registry.SDK.dispatch(&session.ctx, plugin_operations.List, .{}) catch |err| {
        return admin.fail(&session, err, "/admin/settings");
    };
    const arena = session.arena;
    var shown: std.ArrayList(views.Plugins.PluginsItem) = .empty;

    for (listed.plugins) |summary| {
        if (summary.mode != .sandboxed) {
            continue;
        }

        const row = try shown.addOne(arena);
        const base = try std.fmt.allocPrint(arena, "{s}/{s}", .{ back, summary.name });

        row.* = .{
            .href = base,
            .name = summary.name,
            .version = summary.version,
            .summary = summary.summary,
            .enabled = summary.enabled,
            .pending = if (summary.pending == 0) "" else try std.fmt.allocPrint(arena, "{d}", .{
                summary.pending,
            }),
            .update = summary.update orelse "",
            .enable_href = try std.fmt.allocPrint(arena, "{s}/enable", .{base}),
            .update_href = try std.fmt.allocPrint(arena, "{s}/update", .{base}),
            .disable_action = try std.fmt.allocPrint(arena, "{s}/disable", .{base}),
            .remove_action = try std.fmt.allocPrint(arena, "{s}/remove", .{base}),
        };
    }

    const shell = admin.shell_of(&session);

    try admin.render.page(response, arena, .ok, views.Plugins, .{
        .user_name = shell.user_name,
        .user_email = shell.user_email,
        .can_structure = shell.can_structure,
        .can_settings = shell.can_settings,
        .top_bar = shell.top_bar,
        .csrf = shell.csrf,
        .nav = try settings_nav.node(&session, "plugins"),
        .tab = "installed",
        .built_in = &.{},
        .plugins = shown.items,
    });
}

/// The Built-in tab: the plugins compiled into this binary. Nothing to decide about them:
/// a build puts them there, with full access, and only a new build changes them.
pub fn built_in(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;

    if (!registry.SDK.may(&session.ctx, plugin_operations.List)) {
        return admin.fail(&session, error.Denied, "/admin/settings");
    }

    const all = registry.native_plugins.all;
    var shown: [all.len]views.Plugins.Built_inItem = undefined;

    inline for (all, 0..) |Plugin, index| {
        shown[index] = .{
            .name = Plugin.manifest.name,
            .version = Plugin.manifest.version,
            .summary = Plugin.manifest.summary,
            .brings = comptime brings_of(Plugin),
        };
    }

    const shell = admin.shell_of(&session);

    try admin.render.page(response, session.arena, .ok, views.Plugins, .{
        .user_name = shell.user_name,
        .user_email = shell.user_email,
        .can_structure = shell.can_structure,
        .can_settings = shell.can_settings,
        .top_bar = shell.top_bar,
        .csrf = shell.csrf,
        .nav = try settings_nav.node(&session, "plugins"),
        .tab = "built_in",
        .built_in = &shown,
        .plugins = &.{},
    });
}

/// What a native plugin brings, counted: `2 operations, 1 content type, 1 role`.
fn brings_of(comptime Plugin: type) []const u8 {
    comptime {
        const contract = @import("../../sdk/plugin.zig");
        const Count = struct { count: u32, one: []const u8, many: []const u8 };
        const counts = [_]Count{
            .{
                .count = contract.operations_of(Plugin).len,
                .one = "operation",
                .many = "operations",
            },
            .{
                .count = contract.content_types_of(Plugin).len,
                .one = "content type",
                .many = "content types",
            },
            .{ .count = contract.middleware_of(Plugin).len, .one = "hook", .many = "hooks" },
            .{ .count = contract.roles_of(Plugin).len, .one = "role", .many = "roles" },
        };

        std.debug.assert(Plugin.manifest.name.len > 0);
        var text: []const u8 = "";

        for (counts) |item| {
            if (item.count == 0) {
                continue;
            }

            const separator = if (text.len == 0) "" else ", ";
            const noun = if (item.count == 1) item.one else item.many;

            text = text ++ separator ++ std.fmt.comptimePrint("{d} {s}", .{ item.count, noun });
        }

        return if (text.len == 0) "Nothing of its own" else text;
    }
}

/// A plugin's own page.
pub fn show(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const name = try admin.param(&session, "name", back) orelse return;
    const detail = try get(&session, name) orelse return;
    const arena = session.arena;
    const operations = try arena.alloc(views.Plugin.OperationsItem, detail.operations.len);
    const base = try std.fmt.allocPrint(arena, "{s}/{s}", .{ back, detail.name });

    for (detail.operations, operations) |operation, *row| {
        row.* = .{ .name = operation };
    }

    const shell = admin.shell_of(&session);

    try admin.render.page(response, arena, .ok, views.Plugin, .{
        .user_name = shell.user_name,
        .user_email = shell.user_email,
        .can_structure = shell.can_structure,
        .can_settings = shell.can_settings,
        .top_bar = shell.top_bar,
        .csrf = shell.csrf,
        .nav = try settings_nav.node(&session, "plugins"),
        .name = detail.name,
        .version = detail.version,
        .summary = detail.summary,
        .enabled = detail.enabled,
        .update = if (detail.update) |next| next.version else "",
        .update_href = try std.fmt.allocPrint(arena, "{s}/update", .{base}),
        .previous = detail.previous orelse "",
        .enable_href = try std.fmt.allocPrint(arena, "{s}/enable", .{base}),
        .disable_action = try std.fmt.allocPrint(arena, "{s}/disable", .{base}),
        .rollback_action = try std.fmt.allocPrint(arena, "{s}/rollback", .{base}),
        .decide_action = try std.fmt.allocPrint(arena, "{s}/decide", .{base}),
        .access_action = try std.fmt.allocPrint(arena, "{s}/access", .{base}),
        .remove_action = try std.fmt.allocPrint(arena, "{s}/remove", .{base}),
        .requests = try rows.requests(
            views.Plugin.RequestsItem,
            arena,
            detail.requests,
            detail.allowed_domains,
            true,
        ),
        .operations = operations,
        .show_access = detail.uses_content,
        .scope = @tagName(detail.content_access.scope),
        .recommend = @tagName(detail.recommend.recommend),
        .note = detail.recommend.note,
        .types = try rows.type_rows(views.Plugin.TypesItem, &session, detail.content_access.types),
    });
}

/// The enabling screen: what the plugin asks for, before it runs.
pub fn review_enable(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const name = try admin.param(&session, "name", back) orelse return;
    const detail = try get(&session, name) orelse return;
    const arena = session.arena;
    const base = try std.fmt.allocPrint(arena, "{s}/{s}", .{ back, detail.name });

    if (detail.enabled) {
        return session.response.redirect(.see_other, base);
    }

    try render_review(&session, .{
        .title = try std.fmt.allocPrint(arena, "Enable {s} {s}", .{
            detail.name,
            detail.version,
        }),
        .summary = detail.summary,
        .action = try std.fmt.allocPrint(arena, "{s}/enable", .{base}),
        .allow_label = "Allow & Enable",
        .cancel_href = back,
        .discard_action = "",
        .requests_title = "This plugin asks to",
        .requests = try rows.requests(
            views.PluginReview.RequestsItem,
            arena,
            detail.requests,
            detail.allowed_domains,
            false,
        ),
        .granted = &.{},
        .note_text = "Low and medium permissions are granted when it starts; high ones wait " ++
            "until you grant them on its page. You can take any of them back at any time.",
        .show_access = detail.uses_content,
        .scope = @tagName(detail.recommend.recommend),
        .recommend = @tagName(detail.recommend.recommend),
        .note = detail.recommend.note,
        .types = try rows.type_rows(views.PluginReview.TypesItem, &session, &.{}),
    });
}

/// The update screen: the newer version's requests, new ones above what it holds already.
pub fn review_update(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const name = try admin.param(&session, "name", back) orelse return;
    const detail = try get(&session, name) orelse return;
    const arena = session.arena;
    const base = try std.fmt.allocPrint(arena, "{s}/{s}", .{ back, detail.name });
    const next = detail.update orelse return session.response.redirect(.see_other, base);
    const domains = detail.allowed_domains;
    const split = try rows.split_update(arena, next.requests, detail.requests, domains);

    try render_review(&session, .{
        .title = try std.fmt.allocPrint(arena, "Update {s} from {s} to {s}", .{
            detail.name,
            detail.version,
            next.version,
        }),
        .summary = detail.summary,
        .action = try std.fmt.allocPrint(arena, "{s}/update", .{base}),
        .allow_label = "Allow & Update",
        .cancel_href = base,
        .discard_action = try std.fmt.allocPrint(arena, "{s}/cancel-update", .{base}),
        .requests_title = "New permissions",
        .requests = split.fresh,
        .granted = split.held,
        .note_text = "Allowing grants everything the new version asks for. The version it " ++
            "replaces is kept: you can roll back to it from the plugin's page.",
        .show_access = false,
        .scope = "public",
        .recommend = "public",
        .note = "",
        .types = &.{},
    });
}

const Review = struct {
    title: []const u8,
    summary: []const u8,
    action: []const u8,
    allow_label: []const u8,
    cancel_href: []const u8,
    discard_action: []const u8,
    requests_title: []const u8,
    requests: []const views.PluginReview.RequestsItem,
    granted: []const views.PluginReview.GrantedItem,
    note_text: []const u8,
    show_access: bool,
    scope: []const u8,
    recommend: []const u8,
    note: []const u8,
    types: []const views.PluginReview.TypesItem,
};

fn render_review(session: *Session, review: Review) Error!void {
    std.debug.assert(review.title.len > 0);
    std.debug.assert(review.action.len > 0);

    const shell = admin.shell_of(session);

    try admin.render.page(session.response, session.arena, .ok, views.PluginReview, .{
        .user_name = shell.user_name,
        .user_email = shell.user_email,
        .can_structure = shell.can_structure,
        .can_settings = shell.can_settings,
        .top_bar = shell.top_bar,
        .csrf = shell.csrf,
        .nav = try settings_nav.node(session, "plugins"),
        .title = review.title,
        .summary = review.summary,
        .action = review.action,
        .allow_label = review.allow_label,
        .cancel_href = review.cancel_href,
        .discard_action = review.discard_action,
        .requests_title = review.requests_title,
        .requests = review.requests,
        .granted = review.granted,
        .note_text = review.note_text,
        .show_access = review.show_access,
        .scope = review.scope,
        .recommend = review.recommend,
        .note = review.note,
        .types = review.types,
    });
}

pub fn enable(request: *Request, response: *Response, ctx: *Context) Error!void {
    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const name = try admin.param(session, "name", back) orelse return;
    const chosen = rows.access_of(session.arena, &post.form) catch |err| {
        return admin.fail(session, err, back);
    };

    std.debug.assert(request.method() == .post);

    _ = registry.SDK.dispatch(&session.ctx, plugin_operations.Enable, .{
        .name = name,
        .content_access = chosen.scope,
        .types = chosen.types,
    }) catch |err| return admin.fail(session, err, back);

    try redirect_to(session, name);
}

/// Grant, revoke or deny one request.
pub fn decide(request: *Request, response: *Response, ctx: *Context) Error!void {
    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const name = try admin.param(session, "name", back) orelse return;
    const key = post.form.text("key") orelse return admin.fail(session, error.Invalid, back);
    const change = post.form.text("change") orelse "";
    const in: plugin_operations.Revoke.In = .{ .name = name, .key = key };

    std.debug.assert(request.method() == .post);

    const done = if (std.mem.eql(u8, change, "grant"))
        registry.SDK.dispatch(&session.ctx, plugin_operations.GrantRequest, in)
    else if (std.mem.eql(u8, change, "revoke"))
        registry.SDK.dispatch(&session.ctx, plugin_operations.Revoke, in)
    else if (std.mem.eql(u8, change, "deny"))
        registry.SDK.dispatch(&session.ctx, plugin_operations.Deny, in)
    else
        error.Invalid;

    _ = done catch |err| return admin.fail(session, err, back);

    try redirect_to(session, name);
}

pub fn access(request: *Request, response: *Response, ctx: *Context) Error!void {
    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const name = try admin.param(session, "name", back) orelse return;
    const chosen = rows.access_of(session.arena, &post.form) catch |err| {
        return admin.fail(session, err, back);
    };

    std.debug.assert(request.method() == .post);

    _ = registry.SDK.dispatch(&session.ctx, plugin_operations.SetContentAccess, .{
        .name = name,
        .scope = chosen.scope,
        .types = chosen.types,
    }) catch |err| return admin.fail(session, err, back);

    try redirect_to(session, name);
}

/// A change to one plugin by its name alone: it lands back on the plugin's page, or on
/// the list when the form says so (`next=list`) or the plugin is gone.
fn Change(comptime Operation: type) type {
    return struct {
        pub fn handle(request: *Request, response: *Response, ctx: *Context) Error!void {
            var post = try admin.accept(request, response, ctx, back) orelse return;
            const session = &post.session;
            const name = try admin.param(session, "name", back) orelse return;

            std.debug.assert(request.method() == .post);

            _ = registry.SDK.dispatch(&session.ctx, Operation, .{
                .name = name,
            }) catch |err| return admin.fail(session, err, back);

            const to_list = std.mem.eql(u8, post.form.text("next") orelse "", "list");

            if (to_list or Operation == plugin_operations.Remove) {
                return session.response.redirect(.see_other, back);
            }

            try redirect_to(session, name);
        }
    };
}

/// Disable from the plugin's page: the one plugin, refused in words while others need it.
fn disable(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const name = try admin.param(session, "name", back) orelse return;

    _ = registry.SDK.dispatch(&session.ctx, plugin_operations.Disable, .{
        .names = &.{name},
    }) catch |err| return admin.fail(session, err, back);

    if (std.mem.eql(u8, post.form.text("next") orelse "", "list")) {
        return session.response.redirect(.see_other, back);
    }

    try redirect_to(session, name);
}
const update = Change(plugin_operations.Update).handle;
const cancel_update = Change(plugin_operations.CancelUpdate).handle;
const rollback = Change(plugin_operations.Rollback).handle;
const remove = Change(plugin_operations.Remove).handle;

/// The plugin called `name`, or null after the page that says why.
fn get(session: *Session, name: []const u8) Error!?plugin_operations.Detail {
    std.debug.assert(name.len > 0);

    const in: plugin_operations.Get.In = .{ .name = name };

    return registry.SDK.dispatch(&session.ctx, plugin_operations.Get, in) catch |err| {
        try admin.fail(session, err, back);

        return null;
    };
}

fn redirect_to(session: *Session, name: []const u8) Error!void {
    std.debug.assert(name.len > 0);

    const location = try std.fmt.allocPrint(session.arena, "{s}/{s}", .{ back, name });

    try session.response.redirect(.see_other, location);
}
