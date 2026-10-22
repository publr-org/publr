//! Removals: what agents asked to remove for good, listed for the person. A list opens
//! with everything ticked; the person unticks what should stay and removes the rest, as
//! themselves, or keeps everything.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const removal = @import("../../operations/removal.zig");
const ai = @import("../../operations/ai.zig");
const model_ai = @import("../../model/ai.zig");
const time = @import("../../lib/time.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const views = admin.views;

pub const back = "/admin/removals";
const page_size: u32 = 50;
pub const routes_count: u32 = 4;

pub fn register(router: anytype) void {
    std.debug.assert(router.routes_len > 0);

    router.get(back, &lists);
    router.get(back ++ "/:id", &review);
    router.post(back ++ "/:id/confirm", &confirm);
    router.post(back ++ "/:id/decline", &decline);
}

/// `GET /admin/removals`: the person's lists, those waiting first.
pub fn lists(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const offset = admin.pager.offset_of(&session);
    const listed = registry.SDK.dispatch(&session.ctx, removal.List, .{
        .all = true,
        .offset = offset,
        .limit = page_size,
    }) catch |err| {
        return admin.fail(&session, err, "/admin");
    };
    const arena = session.arena;
    const rows = try arena.alloc(views.Removals.ListsItem, listed.lists.len);

    for (listed.lists, rows) |list, *row| {
        const waiting = std.mem.eql(u8, list.state, "waiting");
        const count = if (waiting) list.waiting else list.items;

        row.* = .{
            .href = try std.fmt.allocPrint(arena, "{s}/{s}", .{ back, list.id }),
            .label = try std.fmt.allocPrint(arena, "{d} thing{s} from {s}", .{
                count,
                if (count == 1) "" else "s",
                if (list.conversation_id.len > 0) "a conversation" else "your agent",
            }),
            .waiting = waiting,
            .created = time.datetime_text(arena, list.created_at) catch "",
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

    try admin.screen(&session, .ok, views.Removals, .{
        .lists = rows,
        .range = pages.range,
        .previous_href = pages.previous_href,
        .next_href = pages.next_href,
    }, .{});
}

/// `GET /admin/removals/:id`: one list to review.
pub fn review(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const id = try admin.param(&session, "id", back) orelse return;
    const done = admin.query_param(&session, "done") orelse "";
    const notice = if (done.len > 0)
        try session.translated("Done. What was removed is gone; what you kept stays.", .{})
    else
        "";

    try screen(&session, id, notice, "");
}

fn screen(
    session: *admin.Session,
    id: []const u8,
    notice: []const u8,
    problem: []const u8,
) Error!void {
    std.debug.assert(id.len > 0);
    std.debug.assert(session.signed_in());

    const got = registry.SDK.dispatch(&session.ctx, removal.Get, .{
        .id = id,
    }) catch |err| {
        return admin.fail(session, err, back);
    };
    const arena = session.arena;
    const items = try arena.alloc(views.Removal.ItemsItem, got.items.len);
    var count: u32 = 0;
    var trashable = false;

    for (got.items) |item| {
        const waiting = std.mem.eql(u8, item.state, "waiting");
        const purges = std.mem.endsWith(u8, item.operation, ".purge");

        count += @intFromBool(waiting);
        trashable = trashable or (waiting and purges);
    }

    for (got.items, items) |item, *row| {
        row.* = .{
            .position = @floatFromInt(item.position),
            .label = item.label,
            .detail = item.detail,
            .blocked = item.blocked,
            .state = item.state,
            .message = item.message,
        };
    }

    try admin.screen(session, .ok, views.Removal, .{
        .confirm_action = try std.fmt.allocPrint(arena, "{s}/{s}/confirm", .{ back, id }),
        .decline_action = try std.fmt.allocPrint(arena, "{s}/{s}/decline", .{ back, id }),
        .waiting = std.mem.eql(u8, got.list.state, "waiting"),
        .count = try session.translated_count("{count} thing", "{count} things", count),
        .trashable = trashable,
        .origin = try origin_of(session, got.list.conversation_id),
        .items = items,
        .notice = notice,
        .problem = problem,
    }, .{});
}

/// Where the list came from, in words.
fn origin_of(session: *admin.Session, conversation_id: []const u8) Error![]const u8 {
    std.debug.assert(session.signed_in());

    if (conversation_id.len == 0) {
        return session.translated("Your agent asked to remove these for good.", .{});
    }

    const read = registry.SDK.dispatch(&session.ctx, ai.Get, .{
        .id = conversation_id,
        .after = model_ai.steps_max,
    }) catch return session.translated("An agent asked to remove these for good.", .{});

    const prompt = model_ai.clipped(read.conversation.prompt, 120);

    return session.translated(
        "Your agent asked to remove these for good, in “{prompt}”.",
        .{
            .values = &.{.{
                .name = "prompt",
                .value = prompt,
            }},
        },
    );
}

/// `POST /admin/removals/:id/confirm`: the ticked items removed, the rest kept.
pub fn confirm(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const id = try admin.param(session, "id", back) orelse return;
    const got = registry.SDK.dispatch(&session.ctx, removal.Get, .{
        .id = id,
    }) catch |err| {
        return admin.fail(session, err, back);
    };
    var keep: std.ArrayList(u32) = .empty;

    for (got.items) |item| {
        if (std.mem.eql(u8, item.state, "waiting") and !ticked(&post.form, item.position)) {
            try keep.append(session.arena, item.position);
        }
    }

    _ = registry.SDK.dispatch(&session.ctx, removal.Confirm, .{
        .id = id,
        .keep = keep.items,
        .trash = post.form.get("trash") != null,
    }) catch |err| return admin.fail(session, err, back);

    try response.redirect(.see_other, try std.fmt.allocPrint(session.arena, "{s}/{s}?done=1", .{
        back,
        id,
    }));
}

/// `POST /admin/removals/:id/decline`: everything kept.
pub fn decline(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const id = try admin.param(session, "id", back) orelse return;

    _ = registry.SDK.dispatch(&session.ctx, removal.Decline, .{
        .id = id,
    }) catch |err| {
        return admin.fail(session, err, back);
    };

    try response.redirect(.see_other, try std.fmt.allocPrint(session.arena, "{s}/{s}?done=1", .{
        back,
        id,
    }));
}

/// Whether the form ticked the item at `position`.
fn ticked(form: *const admin.Form, position: u32) bool {
    std.debug.assert(position > 0);

    var buffer: [16]u8 = undefined;
    const wanted = std.fmt.bufPrint(&buffer, "{d}", .{position}) catch return false;

    for (form.pairs[0..form.len]) |pair| {
        if (std.mem.eql(u8, pair.name, "remove") and std.mem.eql(u8, pair.value, wanted)) {
            return true;
        }
    }

    return false;
}
