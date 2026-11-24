//! `/admin/live?since=<revision>&keys=<k1>,<k2>`: whether anything a followed read on an
//! admin page read changed after the revision it was read at (`X-Publr-Follows`). Answered
//! from the change log without the write lock; never a record's content: the page reads
//! again through its operations, as the person, when it changed.
const std = @import("std");
const admin = @import("../admin.zig");
const live = @import("../apps.zig").follow;

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;

pub const route = "/admin/live";
pub const routes_count: u32 = 1;

pub fn register(router: anytype) void {
    std.debug.assert(router.routes_len > 0);

    router.get(route, &answer);
}

pub fn answer(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    const session = try admin.require(request, response, ctx) orelse return;
    const host = session.project.apps_host orelse {
        return response.json(.ok, .{
            .revision = 0,
            .changed = false,
        });
    };

    try response.set_header("Cache-Control", "no-store");

    const now = live.changed_since(host.index, session.arena, request.query()) catch |err| {
        std.log.warn("admin live: the change log unread: {t}", .{err});

        return response.json(.ok, .{
            .revision = 0,
            .changed = false,
        });
    };

    return response.json(.ok, now);
}
