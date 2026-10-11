//! Settings › Trash: what was removed, restorable until it goes for good; Restore, Remove
//! for good, Empty trash.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const trash = @import("../../operations/trash.zig");
const time = @import("../../lib/time.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const views = admin.views;

pub const back = "/admin/trash";
const page_size: u32 = 50;
pub const routes_count: u32 = 5;

pub fn register(router: anytype) void {
    std.debug.assert(router.routes_len > 0);

    router.get(back, &list);
    router.post(back ++ "/empty", &empty);
    router.post(back ++ "/keep", &keep);
    router.post(back ++ "/:id/restore", &restore);
    router.post(back ++ "/:id/remove", &remove);
}

pub fn list(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const done = admin.query_param(&session, "done") orelse "";
    const notice = if (std.mem.eql(u8, done, "restored"))
        try session.translated("Restored, with everything it held.")
    else if (std.mem.eql(u8, done, "removed"))
        try session.translated("Removed for good.")
    else if (std.mem.eql(u8, done, "kept"))
        try session.translated(
            "Saved: everything in the trash goes that many days after it was removed.",
        )
    else
        "";

    try screen(&session, notice, "");
}

fn screen(session: *admin.Session, notice: []const u8, problem: []const u8) Error!void {
    std.debug.assert(session.signed_in());
    std.debug.assert(notice.len == 0 or problem.len == 0);

    const offset = admin.pager.offset_of(session);
    const listed = registry.SDK.dispatch(&session.ctx, trash.List, .{
        .offset = offset,
        .limit = page_size,
    }) catch |err| {
        return admin.fail(session, err, "/admin");
    };
    const arena = session.arena;
    const rows = try arena.alloc(views.Trash.EntriesItem, listed.entries.len);

    for (listed.entries, rows) |entry, *row| {
        const at = time.datetime_text(arena, entry.removed_at) catch "";
        const until = time.datetime_text(arena, entry.keep_until) catch "";
        const when: []const admin.Placeholder = &.{.{
            .name = "when",
            .value = at,
        }};
        const removed = if (entry.conversation_id.len > 0)
            try session.translated_with("By an agent, {when}", when)
        else
            try session.translated_with("By a person, {when}", when);

        row.* = .{
            .label = entry.label,
            .removed = removed,
            .until = until[0 .. std.mem.indexOfScalar(u8, until, ' ') orelse until.len],
            .restore_action = try std.fmt.allocPrint(arena, "{s}/{s}/restore", .{ back, entry.id }),
            .remove_action = try std.fmt.allocPrint(arena, "{s}/{s}/remove", .{ back, entry.id }),
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

    try admin.screen(session, .ok, views.Trash, .{
        .entries = rows,
        .keep_days = @floatFromInt(listed.keep_days),
        .range = pages.range,
        .previous_href = pages.previous_href,
        .next_href = pages.next_href,
        .notice = notice,
        .problem = problem,
    });
}

pub fn restore(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const id = try admin.param(session, "id", back) orelse return;

    _ = registry.SDK.dispatch(&session.ctx, trash.Restore, .{
        .id = id,
    }) catch |err| {
        const failure = if (err == error.Failed) session.ctx.failure else null;

        return screen(session, "", if (failure) |found| found.message else @errorName(err));
    };

    try response.redirect(.see_other, back ++ "?done=restored");
}

pub fn remove(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const id = try admin.param(session, "id", back) orelse return;

    _ = registry.SDK.dispatch(&session.ctx, trash.Remove, .{
        .id = id,
    }) catch |err| {
        return admin.fail(session, err, back);
    };

    try response.redirect(.see_other, back ++ "?done=removed");
}

pub fn empty(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;

    _ = registry.SDK.dispatch(&session.ctx, trash.Empty, .{}) catch |err| {
        return admin.fail(session, err, back);
    };

    try response.redirect(.see_other, back ++ "?done=removed");
}

/// `POST /admin/trash/keep`: how many days the trash keeps things.
pub fn keep(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const text = std.mem.trim(u8, post.form.get("days") orelse "", " ");
    const days = std.fmt.parseInt(u32, text, 10) catch {
        return screen(session, "", try session.translated("Days are a whole number, 1 to 3650."));
    };

    _ = registry.SDK.dispatch(&session.ctx, trash.Keep, .{
        .days = days,
    }) catch {
        return screen(session, "", try session.translated("Days are a whole number, 1 to 3650."));
    };

    try response.redirect(.see_other, back ++ "?done=kept");
}
