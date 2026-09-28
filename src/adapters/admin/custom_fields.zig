//! Named field groups for custom destinations.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const operations = @import("../../operations/custom_fields.zig");
const model = @import("../../model.zig");

pub fn list(
    request: *admin.Request,
    response: *admin.Response,
    ctx: *admin.Context,
) admin.Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    var session = try admin.require(request, response, ctx) orelse return;
    const got = registry.SDK.dispatch(&session.ctx, operations.List, .{}) catch |err| {
        return admin.fail(&session, err, "/admin/structure");
    };
    const rows = try session.arena.alloc(admin.views.CustomFields.GroupsItem, got.groups.len);

    for (got.groups, 0..) |group, index| {
        rows[index] = .{
            .name = group.name,
            .handle = group.handle,
            .href = try std.fmt.allocPrint(
                session.arena,
                "/admin/custom-fields/{s}",
                .{
                    group.handle,
                },
            ),
            .status = if (group.active) "Active" else "Inactive",
        };
    }

    const shell = admin.shell_of(&session);
    try admin.render.page(response, session.arena, .ok, admin.views.CustomFields, .{
        .user_name = shell.user_name,
        .user_email = shell.user_email,
        .can_structure = shell.can_structure,
        .can_settings = shell.can_settings,
        .csrf = shell.csrf,
        .groups = rows,
    });
}

pub fn new_page(
    request: *admin.Request,
    response: *admin.Response,
    ctx: *admin.Context,
) admin.Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    var session = try admin.require(request, response, ctx) orelse return;
    _ = registry.SDK.dispatch(&session.ctx, operations.List, .{}) catch |err| {
        return admin.fail(&session, err, "/admin/custom-fields");
    };
    var def = operations.Destination.user.definition();
    def.name = "";
    def.handle = "";
    def.group.location = &.{.{ .rules = &.{.{ .field = "destination", .value = "user" }} }};
    try @import("field_group.zig").render(&session, response, def, true);
}

pub fn create(
    request: *admin.Request,
    response: *admin.Response,
    ctx: *admin.Context,
) admin.Error!void {
    std.debug.assert(request.method() == .post);
    var post = try admin.accept(request, response, ctx, "/admin/custom-fields/new") orelse return;
    const session = &post.session;
    var def = operations.Destination.user.definition();
    def.handle = post.form.text("handle") orelse "";
    def.name = post.form.text("name") orelse "";
    def.group = @import("field_group.zig").options(session, &post.form) catch |err| {
        return admin.fail(session, err, "/admin/custom-fields/new");
    };
    const encoded = model.content_type.encode(session.arena, def) catch |err| {
        return admin.fail(session, err, "/admin/custom-fields/new");
    };
    _ = registry.SDK.dispatch(&session.ctx, operations.Create, .{
        .group = def.handle,
        .definition = encoded,
    }) catch |err| {
        return admin.fail(session, err, "/admin/custom-fields/new");
    };
    try response.redirect(.see_other, try std.fmt.allocPrint(
        session.arena,
        "/admin/custom-fields/{s}",
        .{def.handle},
    ));
}

pub fn delete(
    request: *admin.Request,
    response: *admin.Response,
    ctx: *admin.Context,
) admin.Error!void {
    std.debug.assert(request.method() == .post);
    var post = try admin.accept(request, response, ctx, "/admin/custom-fields") orelse return;
    const handle = try admin.param(&post.session, "handle", "/admin/custom-fields") orelse return;
    _ = registry.SDK.dispatch(
        &post.session.ctx,
        operations.Delete,
        .{
            .group = handle,
        },
    ) catch |err| {
        return admin.fail(&post.session, err, "/admin/custom-fields");
    };
    try response.redirect(.see_other, "/admin/custom-fields");
}
