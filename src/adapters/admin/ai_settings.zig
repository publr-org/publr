//! Settings › AI: the model providers installed, each with its key, its model and a test,
//! the one conversations use, and the official ones set up in a click.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const providers = @import("../../operations/ai/providers.zig");
const setup = @import("../../operations/ai/setup.zig");
const secret = @import("../../operations/secret.zig");
const plugin_operations = @import("../../operations/plugin.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const views = admin.views;

pub const back = "/admin/settings/ai";

pub fn register(router: anytype) void {
    std.debug.assert(router.routes_len > 0);

    router.get(back, &show);
    router.post(back ++ "/key", &key);
    router.post(back ++ "/choose", &choose);
    router.post(back ++ "/test", &test_provider);
    router.post(back ++ "/set-up", &set_up);
}

pub fn show(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const said = admin.query_param(&session, "said") orelse "";

    try screen(&session, .ok, try notice_of(&session, said), "");
}

fn notice_of(session: *const admin.Session, said: []const u8) Error![]const u8 {
    std.debug.assert(said.len <= 64 << 10);

    if (std.mem.eql(u8, said, "key")) {
        return session.translated("Key saved. It will not be shown again.");
    }

    if (std.mem.eql(u8, said, "chosen")) {
        return session.translated("Saved. Conversations use this provider now.");
    }

    return "";
}

fn screen(
    session: *admin.Session,
    status: admin.Status,
    notice: []const u8,
    problem: []const u8,
) Error!void {
    std.debug.assert(session.signed_in());
    std.debug.assert(notice.len == 0 or problem.len == 0);

    const listed = registry.SDK.dispatch(&session.ctx, providers.Providers, .{}) catch |err| {
        return admin.fail(session, err, "/admin/settings");
    };
    const catalog = registry.SDK.dispatch(&session.ctx, setup.Catalog, .{}) catch |err| {
        return admin.fail(session, err, "/admin/settings");
    };
    const arena = session.arena;
    const rows = try arena.alloc(views.SettingsAi.ProvidersItem, listed.providers.len);

    for (listed.providers, rows) |provider, *row| {
        row.* = try row_of(session, provider, listed.model);
    }

    try mark_pending(session, listed.providers, rows);

    var offered: std.ArrayList(views.SettingsAi.OfferedItem) = .empty;

    for (catalog.offered) |item| {
        if (!item.installed) {
            try offered.append(arena, .{
                .name = item.name,
                .label = item.label,
                .summary = item.summary,
            });
        }
    }

    try admin.screen(session, status, views.SettingsAi, .{
        .providers = rows,
        .offered = offered.items,
        .reached = catalog.reached,
        .notice = notice,
        .problem = problem,
    });
}

/// Each provider whose plugin has requests waiting, marked: the plugins a page at a time.
fn mark_pending(
    session: *admin.Session,
    listed: []const providers.Listed,
    rows: []views.SettingsAi.ProvidersItem,
) Error!void {
    std.debug.assert(listed.len == rows.len);

    const page_size = @import("../../sdk/operation.zig").page_limit_max;
    var offset: u32 = 0;

    while (true) : (offset += page_size) {
        const scratch = try session.ctx.scratch();
        const begun = scratch.mark();
        defer scratch.rewind(begun);

        var paged = session.ctx;

        paged.arena = scratch.allocator();

        const plugins = registry.SDK.dispatch(&paged, plugin_operations.List, .{
            .offset = offset,
            .limit = page_size,
        }) catch |err| {
            // Without the list, nothing is marked waiting: the page draws as it is.
            if (err == error.OutOfMemory) {
                return error.OutOfMemory;
            }

            return;
        };

        for (plugins.plugins) |plugin| {
            for (listed, rows) |provider, *row| {
                if (std.mem.eql(u8, plugin.name, provider.plugin)) {
                    row.pending = plugin.pending > 0;
                }
            }
        }

        if (plugins.plugins.len < page_size) {
            return;
        }
    }
}

fn row_of(
    session: *admin.Session,
    provider: providers.Listed,
    chosen_model: []const u8,
) Error!views.SettingsAi.ProvidersItem {
    std.debug.assert(provider.plugin.len > 0);

    const arena = session.arena;
    const description = provider.description;
    const models = try arena.alloc(views.SettingsAi.ModelsItem, description.models.len);
    const wanted = if (provider.chosen and chosen_model.len > 0)
        chosen_model
    else
        description.default_model;

    for (description.models, models) |model, *shown| {
        const selected = std.mem.eql(u8, model.id, wanted);

        shown.* = .{
            .id = model.id,
            .label = model.label,
            .selected = selected,
        };
    }

    const given = description.key;

    return .{
        .plugin = provider.plugin,
        .label = description.label,
        .chosen = provider.chosen,
        .key_secret = if (given) |found| found.secret else "",
        .key_set = provider.key_set,
        .key_url = if (given) |found| found.create_url else "",
        .key_steps = if (given) |found| try std.mem.join(arena, " ", found.steps) else "",
        .models = models,
        .permissions_href = try std.fmt.allocPrint(arena, "/admin/settings/plugins/{s}", .{
            provider.plugin,
        }),
        .pending = false,
    };
}

fn key(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const asked: secret.Set.In = .{
        .name = post.form.text("name") orelse "",
        .value = post.form.text("value") orelse "",
    };

    _ = registry.SDK.dispatch(&session.ctx, secret.Set, asked) catch |err| {
        return refused(session, err, try session.translated("Paste the whole key."));
    };

    try response.redirect(.see_other, if (from_overview(&post.form))
        overview
    else
        back ++ "?said=key");
}

fn choose(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const asked: providers.Choose.In = .{
        .provider = post.form.text("provider") orelse "",
        .model = post.form.text("model") orelse "",
    };

    _ = registry.SDK.dispatch(&session.ctx, providers.Choose, asked) catch |err| {
        const invalid = try session.translated("That model is not one the provider offers.");

        return refused(session, err, invalid);
    };

    try response.redirect(.see_other, back ++ "?said=chosen");
}

fn test_provider(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const asked: setup.Test.In = .{
        .provider = post.form.text("provider") orelse "",
    };
    const tested = registry.SDK.dispatch(&session.ctx, setup.Test, asked) catch |err| {
        return refused(session, err, "");
    };

    if (!tested.ok) {
        const problem = try session.translated_with("The test call failed: {reply}", &.{.{
            .name = "reply",
            .value = tested.reply,
        }});

        return screen(session, .ok, "", problem);
    }

    const notice = try session.translated_with(
        "It works. The model answered “{reply}”.",
        &.{.{
            .name = "reply",
            .value = tested.reply,
        }},
    );

    try screen(session, .ok, notice, "");
}

/// Where the Overview's forms come back to.
const overview = "/admin?mode=keys";

/// Whether the form was sent from the Overview, which it goes back to.
fn from_overview(form: *const admin.Form) bool {
    std.debug.assert(form.len <= admin.Form.pairs_max);

    const from = form.text("from") orelse return false;

    return std.mem.eql(u8, from, "overview");
}

fn set_up(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const form = &post.form;
    var names: std.ArrayList([]const u8) = .empty;

    for (form.pairs[0..form.len]) |pair| {
        if (std.mem.eql(u8, pair.name, "name") and pair.value.len > 0) {
            try names.append(session.arena, pair.value);
        }
    }

    if (names.items.len == 0) {
        const none = try session.translated("Tick at least one provider.");

        return screen(session, .unprocessable_content, "", none);
    }

    _ = registry.SDK.dispatch(&session.ctx, setup.SetUp, .{
        .names = names.items,
    }) catch |err| {
        return refused(session, err, "");
    };

    try response.redirect(.see_other, if (from_overview(form)) overview else back);
}

/// The page again with why a post was refused: the operation's own words when it gave any.
fn refused(session: *admin.Session, err: anyerror, invalid: []const u8) Error!void {
    std.debug.assert(@errorName(err).len > 0);

    const problem = if (session.ctx.failure) |failure|
        failure.message
    else if ((err == error.Invalid or err == error.Unavailable) and invalid.len > 0)
        invalid
    else
        @errorName(err);

    try screen(session, .unprocessable_content, "", problem);
}
