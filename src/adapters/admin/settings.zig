//! The Settings area's door and its fixed first page: the system's own settings, a
//! placeholder until there is something to configure. Users and the modeled sections
//! have pages of their own.
const std = @import("std");
const admin = @import("../admin.zig");
const settings_nav = @import("settings_nav.zig");

pub fn show(
    request: *admin.Request,
    response: *admin.Response,
    ctx: *admin.Context,
) admin.Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    _ = try admin.require(request, response, ctx) orelse return;

    try response.redirect(.see_other, "/admin/settings/system");
}

pub fn system(
    request: *admin.Request,
    response: *admin.Response,
    ctx: *admin.Context,
) admin.Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const shell = admin.shell_of(&session);

    try admin.render.page(response, session.arena, .ok, admin.views.SettingsSystem, .{
        .user_name = shell.user_name,
        .user_email = shell.user_email,
        .csrf = shell.csrf,
        .nav = try settings_nav.node(&session, "system"),
    });
}
