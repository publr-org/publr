//! Devices in the admin: the list under Settings, with Revoke and how to connect a tool, and
//! the page a device's link opens, where its person approves or denies it.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const device_operations = @import("../../operations/device.zig");
const people = @import("../../operations/device/people.zig");
const role = @import("../../model/role.zig");
const dashboard = @import("dashboard.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const views = admin.views;

pub const back = "/admin/settings/devices";
const page_size: u32 = 50;

pub fn list(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const everyone = session.ctx.caller.holds(role.admin);
    const offset = admin.pager.offset_of(&session);
    const asked: people.List.In = .{
        .all = everyone,
        .offset = offset,
        .limit = page_size,
    };
    const listed = registry.SDK.dispatch(&session.ctx, people.List, asked) catch |err| {
        return admin.fail(&session, err, "/admin/settings");
    };
    const arena = session.arena;
    const rows = try arena.alloc(views.Devices.DevicesItem, listed.devices.len);

    for (listed.devices, rows) |device, *row| {
        row.* = .{
            .name = device.name,
            .scope = device.scope,
            .email = device.email,
            .approved = admin.time_text(arena, device.created_at),
            .used = admin.time_text(arena, device.last_used_at),
            .id = device.id,
            .access_action = try std.fmt.allocPrint(arena, "{s}/{s}/access", .{ back, device.id }),
            .revoke_action = try std.fmt.allocPrint(arena, "{s}/{s}/revoke", .{ back, device.id }),
        };
    }

    const tool = dashboard.tool_of(&session);
    const mcp: dashboard.Mcp = if (tool.len > 0) try dashboard.mcp_of(&session) else .{};
    const pages = try admin.pager.links(
        arena,
        back,
        offset,
        @intCast(rows.len),
        listed.total,
        page_size,
    );

    try admin.screen(&session, .ok, views.Devices, .{
        .tool = tool,
        .mcp_address = mcp.address,
        .mcp_name = mcp.name,
        .mcp_site = mcp.site,
        .reachable = dashboard.reachable(&session),
        .copies = registry.copies_list != null,
        .cursor_link = mcp.cursor_link,
        .everyone = everyone,
        .devices = rows,
        .range = pages.range,
        .previous_href = pages.previous_href,
        .next_href = pages.next_href,
    }, .{});
}

pub fn revoke(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const id = try admin.param(session, "id", back) orelse return;

    _ = registry.SDK.dispatch(&session.ctx, people.Revoke, .{
        .id = id,
    }) catch |err| {
        return admin.fail(session, err, back);
    };

    try response.redirect(.see_other, back);
}

/// Edit access: what the person chose, for the device's next call.
pub fn update(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const id = try admin.param(session, "id", back) orelse return;

    _ = registry.SDK.dispatch(&session.ctx, people.Update, .{
        .id = id,
        .scope = chosen_scope(&post.form),
    }) catch |err| {
        return admin.fail(session, err, back);
    };

    try response.redirect(.see_other, back);
}

/// The access form's choices as a scope: each counts only under the one before it, however
/// the boxes were left.
fn chosen_scope(form: anytype) []const u8 {
    const access = form.text("access") orelse "";

    std.debug.assert(access.len <= 1 << 20);

    const writes = std.mem.eql(u8, access, "write");
    const production = form.text("production") != null;
    const publishes = form.text("publish") != null;

    if (!writes) {
        return "read";
    }

    if (registry.copies_list != null and !production) {
        return "write";
    }

    if (publishes) {
        return "publish";
    }

    return if (registry.copies_list != null) "production" else "write";
}

/// Read and write to begin with, or what it asked for when that is less.
fn first_choice(asked: []const u8) []const u8 {
    std.debug.assert(asked.len > 0);

    return if (std.mem.eql(u8, asked, "read")) "read" else "write";
}

/// `/admin/settings/devices/approve?code=WXYZ-BCDF`: what the device asks for. Signed out,
/// the login brings the person back here.
pub fn approve_page(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const code = admin.query_param(&session, "code") orelse "";
    const waiting = registry.SDK.dispatch(&session.ctx, people.Request, .{
        .code = code,
    });
    const asked = waiting catch |err| switch (err) {
        error.NotFound => return gone(&session),
        else => return admin.fail(&session, err, back),
    };

    try admin.screen(&session, .ok, views.DeviceApprove, .{
        .name = asked.name,
        .code = code,
        .email = session.identity.email,
        .asked = asked.scope,
        .chosen = first_choice(asked.scope),
        .copies = registry.copies_list != null,
        .returns_to = asked.returns_to,
    }, .{});
}

/// The person's decision: Approve with the access they chose, or Deny.
pub fn decide(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const code = post.form.text("code") orelse "";
    const approving = std.mem.eql(u8, post.form.text("decision") orelse "", "approve");
    const asked = registry.SDK.dispatch(&session.ctx, people.Request, .{
        .code = code,
    }) catch {
        return gone(session);
    };

    if (approving) {
        const scope = chosen_scope(&post.form);

        const approved = registry.SDK.dispatch(&session.ctx, people.Approve, .{
            .code = code,
            .scope = scope,
        }) catch |err| return admin.fail(session, err, back);

        if (approved.sent_back.len > 0) {
            return session.response.redirect(.see_other, approved.sent_back);
        }

        const acts = try session.translated(
            "{device} can act for you now.",
            .{
                .values = &.{.{
                    .name = "device",
                    .value = asked.name,
                }},
            },
        );
        const close = try session.translated("Go back to it; this page can be closed.", .{});
        const text = try std.fmt.allocPrint(session.arena, "{s} {s}", .{ acts, close });
        const heading = try session.translated("Device approved", .{});

        return admin.message(session, heading, text, &[_]Problem{}, back, .{});
    }

    const denied = registry.SDK.dispatch(&session.ctx, people.Deny, .{
        .code = code,
    }) catch |err| {
        return admin.fail(session, err, back);
    };

    if (denied.sent_back.len > 0) {
        return session.response.redirect(.see_other, denied.sent_back);
    }

    const text = try session.translated(
        "{device} was turned away.",
        .{
            .values = &.{.{
                .name = "device",
                .value = asked.name,
            }},
        },
    );
    const heading = try session.translated("Device denied", .{});

    try admin.message(session, heading, text, &[_]Problem{}, back, .{});
}

const Problem = struct {
    path: []const u8,
    message: []const u8,
};

fn gone(session: *const admin.Session) Error!void {
    std.debug.assert(session.signed_in());
    std.debug.assert(device_operations.approve_path.len > 0);

    const passed = try session.translated(
        "It was approved or denied already, or ten minutes passed.",
        .{},
    );
    const again = try session.translated("Ask the device to sign in again for a new link.", .{});
    const text = try std.fmt.allocPrint(session.arena, "{s} {s}", .{ passed, again });
    const heading = try session.translated("This request is not waiting", .{});

    try admin.message(session, heading, text, &[_]Problem{}, back, .{});
}
