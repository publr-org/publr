//! The corner chat's frame: while the agent works, the page it was asked on is drawn in a
//! frame filling the window, the chat above it on a page that never reloads.

const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const ai = @import("../../operations/ai.zig");
const ai_model = @import("../../model/ai.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;

pub fn register(router: anytype) void {
    std.debug.assert(router.routes_len > 0);

    router.get("/admin/ai/:id/around", &around);
}

/// `GET /admin/ai/:id/around?page=…`: `page` in a frame filling the window, the
/// conversation in the corner above it. The person's own conversations only; a page that
/// may not be wrapped opens the workspace instead.
pub fn around(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const id = try admin.param(&session, "id", "/admin") orelse return;
    const read = registry.SDK.dispatch(&session.ctx, ai.Get, .{
        .id = id,
        .after = ai_model.steps_max,
    }) catch |err| {
        return admin.fail(&session, err, "/admin");
    };
    const page = admin.query_param(&session, "page") orelse "";
    const own = try std.fmt.allocPrint(session.arena, "/admin/ai/{s}", .{read.conversation.id});

    if (admin.chrome.framed(&session) or !ai_model.wrappable(page)) {
        return response.redirect(.see_other, own);
    }

    const asked = ai_model.asked_of(read.conversation.prompt);

    try admin.screen(&session, .ok, admin.views.AiAround, .{
        .title = ai_model.summary_of(asked.words),
        .frame_url = try std.mem.concat(session.arena, u8, &.{
            session.project.admin_path(),
            page,
        }),
    }, .{});
}
