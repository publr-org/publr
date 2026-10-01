const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const caller_module = @import("caller.zig");
const operation = @import("operation.zig");
const Harness = @import("../sdk.zig").testing.Harness;
const grant = @import("grant.zig");
const role = @import("../model/role.zig");
const plugin_access = @import("plugin_access.zig");

const Grant = grant.Grant;
const Role = role.Role;

pub const policies_max: u32 = 64;

pub const Request = struct {
    operation_name: []const u8,
    kind: operation.Kind,
    resource: operation.Resource,
    /// The operation says anyone may call it (`pub const open = true`), like signing in:
    /// a plugin's own open door, such as creating an account. Policies still narrow it.
    open: bool = false,
};

pub const Policy = *const fn (ctx: *const Ctx, request: Request) Grant;

pub const open_operations = [_][]const u8{
    "project.init",
    "project.status",
    "user.set_password",
    "user.sign_in",
    "user.sign_out",
};
pub const admin_namespaces = [_][]const u8{
    "user",
    "settings",
    "custom_fields",
    "sign_on",
    "identity",
    "role",
    "plugin",
};
pub const public_read_namespaces = [_][]const u8{ "heartbeat", "record", "term" };

const delivery_grant: Grant = .{
    .read_only = true,
    .record_filter = .{ .flags = .{ .live_only = true } },
};

/// What the core allows before any plugin narrows it: anonymous callers read live public
/// records; a signed-in account what its roles grant; the system everything; a plugin or a
/// machine token its listed capabilities.
pub fn core_policy(ctx: *const Ctx, request: Request, roles: []const Role) operation.Error!Grant {
    std.debug.assert(request.operation_name.len > 0);
    std.debug.assert(std.mem.indexOfScalar(u8, request.operation_name, '.') != null);

    if (request.open) {
        return Grant.allow_all;
    }

    return switch (ctx.caller) {
        .anonymous => anonymous_grant(request),
        .user => |user| role_grant(roles, user.roles, request),
        .token => Grant.allow_all,
        .machine => scoped_grant(ctx, request),
        .plugin => |plugin| if (plugin.access != null)
            try plugin_grant(ctx, request, roles)
        else
            scoped_grant(ctx, request),
        .system => Grant.allow_all,
    };
}

/// Everything one of the account's roles grants, and the doors open to everyone. Short of
/// a grant, a signed-in account gets what an anonymous visitor gets: live records of public
/// types, so an app's pages read those for its visitors whatever their roles.
fn role_grant(roles: []const Role, held: []const []const u8, request: Request) Grant {
    std.debug.assert(request.operation_name.len > 0);
    std.debug.assert(held.len <= role.user_roles_max);

    if (is_open_operation(request.operation_name)) {
        return Grant.allow_all;
    }

    if (role.permit(roles, held, request.operation_name)) {
        return Grant.allow_all;
    }

    return anonymous_grant(request);
}

pub fn is_open_operation(operation_name: []const u8) bool {
    std.debug.assert(operation_name.len > 0);
    std.debug.assert(open_operations.len == 5);

    for (open_operations) |name| {
        if (std.mem.eql(u8, operation_name, name)) {
            return true;
        }
    }

    return false;
}

pub fn is_public_read_namespace(operation_name: []const u8) bool {
    std.debug.assert(operation_name.len > 0);
    std.debug.assert(public_read_namespaces.len == 3);

    for (public_read_namespaces) |namespace| {
        if (std.mem.eql(u8, operation.namespace(operation_name), namespace)) {
            return true;
        }
    }

    return false;
}

fn is_admin_namespace(operation_name: []const u8) bool {
    std.debug.assert(operation_name.len > 0);
    std.debug.assert(admin_namespaces.len == 7);

    for (admin_namespaces) |namespace| {
        if (std.mem.eql(u8, operation.namespace(operation_name), namespace)) {
            return true;
        }
    }

    return false;
}

fn anonymous_grant(request: Request) Grant {
    if (is_open_operation(request.operation_name)) {
        return Grant.allow_all;
    }

    if (is_admin_namespace(request.operation_name)) {
        return Grant.deny;
    }

    if (request.kind == .write or !is_public_read_namespace(request.operation_name)) {
        return Grant.deny;
    }

    const granted: Grant = .{
        .read_only = true,
        .record_filter = .{ .flags = .{ .live_only = true, .public_types_only = true } },
    };

    std.debug.assert(granted.allows());
    std.debug.assert(granted.read_only);

    return granted;
}

/// An installed plugin's grant, narrowed to the roles of the account it acts for, if any.
fn plugin_grant(ctx: *const Ctx, request: Request, roles: []const Role) operation.Error!Grant {
    const plugin = ctx.caller.plugin;
    const access = plugin.access.?;

    std.debug.assert(request.operation_name.len > 0);
    std.debug.assert(plugin.name.len > 0);

    const granted = plugin_access.grant(plugin.name, access, .{
        .operation_name = request.operation_name,
        .kind = request.kind,
        .type_id = request.resource.type_id,
    });
    const held = plugin.roles orelse return granted;

    return Grant.intersect(granted, role_grant(roles, held, request), ctx.arena);
}

fn scoped_grant(ctx: *const Ctx, request: Request) Grant {
    std.debug.assert(ctx.caller == .machine or ctx.caller == .plugin);
    std.debug.assert(request.operation_name.len > 0);

    if (ctx.caller.has_capability(request.operation_name)) {
        return Grant.allow_all;
    }

    if (ctx.caller.has_capability(operation.namespace(request.operation_name))) {
        return Grant.allow_all;
    }

    return Grant.deny;
}

pub fn authorize(
    ctx: *const Ctx,
    request: Request,
    policies: []const Policy,
    roles: []const Role,
) operation.Error!Grant {
    std.debug.assert(policies.len <= policies_max);
    std.debug.assert(request.operation_name.len > 0);

    var result = try core_policy(ctx, request, roles);

    for (policies) |policy| {
        if (!result.allows()) {
            break;
        }
        result = try Grant.intersect(result, policy(ctx, request), ctx.arena);
    }

    if (ctx.delivery and result.allows()) {
        result = try Grant.intersect(result, delivery_grant, ctx.arena);
    }

    if (ctx.app_plugins) |plugins| {
        if (result.allows()) {
            result = try Grant.intersect(result, .{ .plugins = plugins }, ctx.arena);
        }
    }

    if (!result.allows()) {
        return error.Denied;
    }

    if (result.read_only and request.kind == .write) {
        return error.Denied;
    }

    return result;
}

test "core policy: anonymous reads live+public only, writes denied; users and system full" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const read: Request = .{ .operation_name = "record.get", .kind = .read, .resource = .{} };
    const write: Request = .{ .operation_name = "record.save", .kind = .write, .resource = .{} };

    var anon = harness.ctx(.anonymous);
    const granted = try authorize(&anon, read, &.{}, &role.core);
    try std.testing.expect(granted.read_only);
    try std.testing.expect(granted.record_filter.flags.live_only);
    try std.testing.expect(granted.record_filter.flags.public_types_only);
    try std.testing.expectError(error.Denied, authorize(&anon, write, &.{}, &role.core));

    var user = harness.ctx(.{ .user = .{ .id = "u_1" } });
    const full = try authorize(&user, write, &.{}, &role.core);
    try std.testing.expect(!full.read_only);
    try std.testing.expectEqual(@as(?[]const []const u8, null), full.types);

    const setup: Request = .{ .operation_name = "project.init", .kind = .write, .resource = .{} };
    const login: Request = .{
        .operation_name = "user.sign_in",
        .kind = .write,
        .resource = .{},
    };
    try std.testing.expect(!(try authorize(&anon, setup, &.{}, &role.core)).read_only);
    try std.testing.expect(!(try authorize(&anon, login, &.{}, &role.core)).read_only);

    const signup: Request = .{
        .operation_name = "plugin.sign_up",
        .kind = .write,
        .resource = .{},
        .open = true,
    };
    const closed: Request = .{
        .operation_name = "plugin.sign_up",
        .kind = .write,
        .resource = .{},
    };
    try std.testing.expect(!(try authorize(&anon, signup, &.{}, &role.core)).read_only);
    try std.testing.expectError(error.Denied, authorize(&anon, closed, &.{}, &role.core));
    try std.testing.expectError(error.Denied, authorize(&anon, signup, &.{&deny_all}, &role.core));

    var editor = harness.ctx(.{ .user = .{ .id = "u_2", .roles = &.{"editor"} } });
    const sign_out: Request = .{
        .operation_name = "user.sign_out",
        .kind = .write,
        .resource = .{},
    };
    try std.testing.expect((try authorize(&editor, sign_out, &.{}, &role.core)).allows());
}

test "delivery narrows any caller to live, read-only records and keeps the caller's own limits" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const read: Request = .{ .operation_name = "record.list", .kind = .read, .resource = .{} };
    const write: Request = .{ .operation_name = "record.save", .kind = .write, .resource = .{} };
    const users_list: Request = .{ .operation_name = "user.list", .kind = .read, .resource = .{} };

    var admin = harness.ctx(.{ .user = .{ .id = "u_1", .roles = &.{"admin"} } });
    admin.delivery = true;
    const granted = try authorize(&admin, read, &.{}, &role.core);
    try std.testing.expect(granted.read_only);
    try std.testing.expect(granted.record_filter.flags.live_only);
    try std.testing.expect(!granted.record_filter.flags.public_types_only);
    try std.testing.expectError(error.Denied, authorize(&admin, write, &.{}, &role.core));

    var editor = harness.ctx(.{ .user = .{ .id = "u_2", .roles = &.{"editor"} } });
    editor.delivery = true;
    try std.testing.expectError(error.Denied, authorize(&editor, users_list, &.{}, &role.core));
    const posts_only = try authorize(&editor, read, &.{&only_posts}, &role.core);
    try std.testing.expect(!posts_only.allows_type("page"));

    var anon = harness.ctx(.anonymous);
    anon.delivery = true;
    const anonymous = try authorize(&anon, read, &.{}, &role.core);
    try std.testing.expect(anonymous.record_filter.flags.public_types_only);
}

test "roles: editors are denied the users and settings namespaces, admins are not" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var editor = harness.ctx(.{ .user = .{ .id = "u_2", .roles = &.{"editor"} } });
    var admin = harness.ctx(.{ .user = .{ .id = "u_1", .roles = &.{"admin"} } });
    const users_list: Request = .{ .operation_name = "user.list", .kind = .read, .resource = .{} };
    const entries_save: Request = .{
        .operation_name = "record.save",
        .kind = .write,
        .resource = .{},
    };

    var anon = harness.ctx(.anonymous);
    try std.testing.expectError(error.Denied, authorize(&editor, users_list, &.{}, &role.core));
    try std.testing.expectError(error.Denied, authorize(&anon, users_list, &.{}, &role.core));
    try std.testing.expect((try authorize(&editor, entries_save, &.{}, &role.core)).allows());
    try std.testing.expect((try authorize(&admin, users_list, &.{}, &role.core)).allows());
}

test "plugin policies intersect and can deny" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var user = harness.ctx(.{ .user = .{ .id = "u_1" } });
    const write: Request = .{ .operation_name = "record.save", .kind = .write, .resource = .{} };

    const constrained = try authorize(&user, write, &.{&only_posts}, &role.core);
    try std.testing.expect(constrained.allows_type("post"));
    try std.testing.expect(!constrained.allows_type("page"));

    const denied = authorize(&user, write, &.{ &only_posts, &deny_all }, &role.core);
    try std.testing.expectError(error.Denied, denied);
}

fn only_posts(_: *const Ctx, _: Request) Grant {
    return .{ .types = &.{"post"} };
}

fn deny_all(_: *const Ctx, _: Request) Grant {
    return Grant.deny;
}
