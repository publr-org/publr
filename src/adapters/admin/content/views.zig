//! Saving the content list's filters as a view: create, save changes, rename, delete.
//! Each is a form on the list page; every one lands back on the list.
const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const model = @import("../../../model.zig");
const saved_views = @import("../../../operations/view.zig");
const filters = @import("filters.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const Session = admin.Session;

pub const back = "/admin/content";

/// `name` and `filters` (the list's query string) make a new view; lands on it.
pub fn create(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const name = post.form.text("name") orelse "";
    const query = try query_json(session, post.form.get("filters") orelse "");
    const created = registry.SDK.dispatch(&session.ctx, saved_views.Create, .{
        .name = name,
        .query = query,
    }) catch |err| return admin.fail(session, err, back);

    try session.response.redirect(.see_other, try view_href(session, created.id));
}

/// The filters in force replace the view's.
pub fn save(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const id = try admin.param(session, "id", back) orelse return;
    const query = try query_json(session, post.form.get("filters") orelse "");

    _ = registry.SDK.dispatch(&session.ctx, saved_views.Update, .{
        .id = id,
        .query = query,
    }) catch |err| return admin.fail(session, err, back);

    try session.response.redirect(.see_other, try view_href(session, id));
}

pub fn rename(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const id = try admin.param(session, "id", back) orelse return;
    const name = post.form.text("name") orelse "";

    _ = registry.SDK.dispatch(&session.ctx, saved_views.Update, .{
        .id = id,
        .name = name,
    }) catch |err| return admin.fail(session, err, back);

    try session.response.redirect(.see_other, try view_href(session, id));
}

pub fn delete(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const id = try admin.param(session, "id", back) orelse return;

    _ = registry.SDK.dispatch(&session.ctx, saved_views.Delete, .{ .id = id }) catch |err| {
        return admin.fail(session, err, back);
    };

    try session.response.redirect(.see_other, back);
}

/// The list's query string as the JSON a view keeps.
fn query_json(session: *Session, query: []const u8) Error![]const u8 {
    std.debug.assert(session.signed_in());

    if (query.len > filters.query_len_max) {
        return "{}";
    }

    const parsed = try filters.parse(session.arena, query);

    return model.view.encode(session.arena, parsed) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Invalid => "{}",
    };
}

fn view_href(session: *Session, id: []const u8) Error![]const u8 {
    std.debug.assert(id.len > 0);
    std.debug.assert(back.len > 0);

    return std.fmt.allocPrint(session.arena, "{s}?view={s}", .{ back, id }) catch {
        return error.OutOfMemory;
    };
}
