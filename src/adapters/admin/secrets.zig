//! Settings › Secrets: what plugins declare and what is set, with the plugins using each, a
//! value pasted for each (never shown again), and Remove.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const secret = @import("../../operations/secret.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const views = admin.views;

pub const back = "/admin/settings/secrets";
const page_size: u32 = 50;

pub fn register(router: anytype) void {
    std.debug.assert(router.routes_len > 0);

    router.get(back, &list);
    router.post(back ++ "/set", &set);
    router.post(back ++ "/:name/remove", &remove);
}

pub fn list(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const saved = admin.query_param(&session, "saved") orelse "";
    const notice = if (saved.len > 0)
        try session.translated("Saved. The value will not be shown again.", .{})
    else
        "";

    try screen(&session, .ok, notice, "");
}

fn screen(
    session: *admin.Session,
    status: admin.Status,
    notice: []const u8,
    problem: []const u8,
) Error!void {
    std.debug.assert(session.signed_in());
    std.debug.assert(notice.len == 0 or problem.len == 0);

    const offset = admin.pager.offset_of(session);
    const listed = registry.SDK.dispatch(&session.ctx, secret.List, .{
        .offset = offset,
        .limit = page_size,
    }) catch |err| {
        return admin.fail(session, err, "/admin/settings");
    };
    const arena = session.arena;
    const rows = try arena.alloc(views.Secrets.SecretsItem, listed.secrets.len);

    for (listed.secrets, rows) |item, *row| {
        const kept = std.mem.eql(u8, item.source, "kept");

        row.* = .{
            .name = item.name,
            .source = item.source,
            .used_by = try std.mem.join(arena, ", ", item.used_by),
            .remove_action = if (kept)
                try std.fmt.allocPrint(arena, "{s}/{s}/remove", .{ back, item.name })
            else
                "",
        };
    }

    const pages = try admin.pager.links(
        arena,
        back,
        offset,
        @intCast(rows.len),
        listed.total,
        page_size,
    );

    try admin.screen(session, status, views.Secrets, .{
        .secrets = rows,
        .key = listed.key,
        .range = pages.range,
        .previous_href = pages.previous_href,
        .next_href = pages.next_href,
        .notice = notice,
        .problem = problem,
    }, .{});
}

/// `POST /admin/settings/secrets/set`: a value for a secret, new or replacing.
pub fn set(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const name = std.mem.trim(u8, post.form.text("name") orelse "", " \t");
    const value = post.form.text("value") orelse "";

    const asked: secret.Set.In = .{
        .name = name,
        .value = value,
    };

    _ = registry.SDK.dispatch(&session.ctx, secret.Set, asked) catch |err| {
        const problem = if (err == error.Invalid)
            "A name is capitals, digits and underscores (STOCKS_API_KEY), and a value is not empty."
        else if (session.ctx.failure) |failure| failure.message else @errorName(err);

        return screen(session, .unprocessable_content, "", problem);
    };

    try response.redirect(.see_other, back ++ "?saved=1");
}

/// `POST /admin/settings/secrets/:name/remove`.
pub fn remove(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const name = try admin.param(session, "name", back) orelse return;

    _ = registry.SDK.dispatch(&session.ctx, secret.Remove, .{
        .name = name,
    }) catch |err| {
        return admin.fail(session, err, back);
    };

    try response.redirect(.see_other, back);
}
