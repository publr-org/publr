const std = @import("std");
const admin = @import("../admin.zig");

pub fn show(
    request: *admin.Request,
    response: *admin.Response,
    ctx: *admin.Context,
) admin.Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    const session = try admin.require(request, response, ctx) orelse return;
    const shell = admin.shell_of(&session);

    try admin.render.page(response, session.arena, .ok, admin.views.Structure, .{
        .user_name = shell.user_name,
        .user_email = shell.user_email,
        .csrf = shell.csrf,
    });
}
