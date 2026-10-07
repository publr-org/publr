//! Devices in the admin: the list under Settings, with Revoke, and the page a device's link
//! opens, where its person approves or denies it.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const device_operations = @import("../../operations/device.zig");
const people = @import("../../operations/device/people.zig");
const role = @import("../../model/role.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const views = admin.views;

pub const back = "/admin/settings/devices";

pub fn list(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const everyone = session.ctx.caller.holds(role.admin);
    const asked: people.List.In = .{ .all = everyone };
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
            .revoke_action = try std.fmt.allocPrint(arena, "{s}/{s}/revoke", .{ back, device.id }),
        };
    }

    try admin.screen(&session, .ok, views.Devices, .{ .everyone = everyone, .devices = rows });
}

pub fn revoke(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const id = try admin.param(session, "id", back) orelse return;

    _ = registry.SDK.dispatch(&session.ctx, people.Revoke, .{ .id = id }) catch |err| {
        return admin.fail(session, err, back);
    };

    try response.redirect(.see_other, back);
}

/// `/admin/settings/devices/approve?code=WXYZ-BCDF`: what the device asks for. Signed out,
/// the login brings the person back here.
pub fn approve_page(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const code = admin.query_param(&session, "code") orelse "";
    const waiting = registry.SDK.dispatch(&session.ctx, people.Request, .{ .code = code });
    const asked = waiting catch |err| switch (err) {
        error.NotFound => return gone(&session),
        else => return admin.fail(&session, err, back),
    };

    try admin.screen(&session, .ok, views.DeviceApprove, .{
        .name = asked.name,
        .code = code,
        .email = session.identity.email,
        .asked = asked.scope,
    });
}

/// The person's decision: Approve with the scope they chose, or Deny.
pub fn decide(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const code = post.form.text("code") orelse "";
    const approving = std.mem.eql(u8, post.form.text("decision") orelse "", "approve");
    const asked = registry.SDK.dispatch(&session.ctx, people.Request, .{ .code = code }) catch {
        return gone(session);
    };

    if (approving) {
        const scope = post.form.text("scope") orelse asked.scope;

        _ = registry.SDK.dispatch(&session.ctx, people.Approve, .{
            .code = code,
            .scope = scope,
        }) catch |err| return admin.fail(session, err, back);

        const text = try std.fmt.allocPrint(session.arena, "{s} can act for you now. " ++
            "Go back to it; this page can be closed.", .{asked.name});

        return admin.message(session, "Device approved", text, &[_]Problem{}, back);
    }

    _ = registry.SDK.dispatch(&session.ctx, people.Deny, .{ .code = code }) catch |err| {
        return admin.fail(session, err, back);
    };

    const text = try std.fmt.allocPrint(session.arena, "{s} was turned away.", .{asked.name});

    try admin.message(session, "Device denied", text, &[_]Problem{}, back);
}

const Problem = struct { path: []const u8, message: []const u8 };

fn gone(session: *const admin.Session) Error!void {
    std.debug.assert(session.signed_in());
    std.debug.assert(device_operations.approve_path.len > 0);

    try admin.message(
        session,
        "This request is not waiting",
        "It was approved or denied already, or ten minutes passed. Ask the device to sign " ++
            "in again for a new link.",
        &[_]Problem{},
        back,
    );
}
