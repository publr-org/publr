//! Settings › User types: each type of user a plugin registers (customers, members), and the
//! apps its people may sign in to, switched on or off per app.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const user_type = @import("../../operations/user_type.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const views = admin.views;

pub const back = "/admin/settings/user-types";
const Shown = views.UserTypes.TypesItem;
const AppChoice = std.meta.Child(@FieldType(Shown, "apps"));
pub const routes_count: u32 = 2;

pub fn register(router: anytype) void {
    std.debug.assert(router.routes_len > 0);

    router.get(back, &list);
    router.post(back ++ "/:user_type", &save);
}

pub fn list(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const saved = admin.query_param(&session, "saved") != null;
    const notice = if (saved) try session.translated("Saved.", .{}) else "";

    try screen(&session, notice);
}

fn screen(session: *admin.Session, notice: []const u8) Error!void {
    std.debug.assert(session.signed_in());

    const arena = session.arena;
    const listed = registry.SDK.dispatch(&session.ctx, user_type.List, .{}) catch |err| {
        return admin.fail(session, err, "/admin/settings");
    };
    const shown = try arena.alloc(Shown, listed.types.len);
    const apps = session.project.apps;

    for (listed.types, shown) |one, *item| {
        const choices = try arena.alloc(AppChoice, apps.len);

        for (apps, choices) |*app, *choice| {
            choice.* = .{
                .name = app.spec.name,
                .label = app.spec.label,
                .on = opened(one.apps, app.spec.name),
            };
        }

        item.* = .{
            .name = one.name,
            .label = one.label,
            .plugin = one.plugin,
            .action = try std.fmt.allocPrint(arena, "{s}/{s}", .{ back, one.name }),
            .refused_role = one.refused_role,
            .apps = choices,
        };
    }

    try admin.screen(session, .ok, views.UserTypes, .{
        .types = shown,
        .notice = notice,
    }, .{});
}

fn opened(apps: []const []const u8, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (apps) |each| {
        if (std.mem.eql(u8, each, name)) {
            return true;
        }
    }

    return false;
}

/// `POST /admin/settings/user-types/:user_type`: the apps switched on (`app`, repeated).
pub fn save(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const name = try admin.param(session, "user_type", back) orelse return;
    var apps: std.ArrayList([]const u8) = .empty;

    for (post.form.pairs[0..post.form.len]) |pair| {
        if (std.mem.eql(u8, pair.name, "app") and pair.value.len > 0) {
            try apps.append(session.arena, pair.value);
        }
    }

    _ = registry.SDK.dispatch(&session.ctx, user_type.Set, .{
        .user_type = name,
        .apps = apps.items,
    }) catch |err| {
        return admin.fail(session, err, back);
    };

    try response.redirect(.see_other, back ++ "?saved=1");
}
