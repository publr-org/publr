const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const caller_module = @import("caller.zig");
const operation = @import("operation.zig");
const Harness = @import("../sdk.zig").testing.Harness;
const grant = @import("grant.zig");

const Grant = grant.Grant;

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
    "site.init",
    "site.status",
    "user.set_password",
    "user.sign_in",
    "user.sign_out",
};
pub const admin_namespaces = [_][]const u8{ "user", "settings", "custom_fields", "sign_on" };
pub const admin_write_namespaces = [_][]const u8{ "content_type", "taxonomy" };
pub const admin_operations = [_][]const u8{ "record.purge", "term.purge" };
pub const public_read_namespaces = [_][]const u8{ "heartbeat", "record", "term" };

const delivery_grant: Grant = .{
    .read_only = true,
    .record_filter = .{ .flags = .{ .live_only = true } },
};

pub fn core_policy(ctx: *const Ctx, request: Request) Grant {
    std.debug.assert(request.operation_name.len > 0);
    std.debug.assert(std.mem.indexOfScalar(u8, request.operation_name, '.') != null);

    if (request.open) {
        return Grant.allow_all;
    }

    return switch (ctx.caller) {
        .anonymous => anonymous_grant(request),
        .user => |user| role_grant(user.role, request),
        .token => Grant.allow_all,
        .machine, .plugin => scoped_grant(ctx, request),
        .system => Grant.allow_all,
    };
}

fn role_grant(role: caller_module.Role, request: Request) Grant {
    std.debug.assert(request.operation_name.len > 0);
    std.debug.assert(admin_namespaces.len == 4);

    switch (role) {
        .admin => return Grant.allow_all,
        .editor => {
            if (is_open_operation(request.operation_name)) {
                return Grant.allow_all;
            }

            if (std.mem.eql(u8, request.operation_name, "user.options") and request.kind == .read) {
                return Grant.allow_all;
            }

            if (is_admin_namespace(request.operation_name)) {
                return Grant.deny;
            }

            if (request.kind == .write and is_admin_write_namespace(request.operation_name)) {
                return Grant.deny;
            }

            if (is_admin_operation(request.operation_name)) {
                return Grant.deny;
            }

            return Grant.allow_all;
        },
    }
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

fn is_admin_operation(operation_name: []const u8) bool {
    std.debug.assert(operation_name.len > 0);
    std.debug.assert(admin_operations.len == 2);

    for (admin_operations) |name| {
        if (std.mem.eql(u8, operation_name, name)) {
            return true;
        }
    }

    return false;
}

fn is_admin_write_namespace(operation_name: []const u8) bool {
    std.debug.assert(operation_name.len > 0);
    std.debug.assert(admin_write_namespaces.len == 2);

    for (admin_write_namespaces) |namespace| {
        if (std.mem.eql(u8, operation.namespace(operation_name), namespace)) {
            return true;
        }
    }

    return false;
}

fn is_admin_namespace(operation_name: []const u8) bool {
    std.debug.assert(operation_name.len > 0);
    std.debug.assert(admin_namespaces.len == 4);

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
) operation.Error!Grant {
    std.debug.assert(policies.len <= policies_max);
    std.debug.assert(request.operation_name.len > 0);

    var result = core_policy(ctx, request);

    for (policies) |policy| {
        if (!result.allows()) {
            break;
        }
        result = try Grant.intersect(result, policy(ctx, request), ctx.arena);
    }

    if (ctx.delivery and result.allows()) {
        result = try Grant.intersect(result, delivery_grant, ctx.arena);
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
    const granted = try authorize(&anon, read, &.{});
    try std.testing.expect(granted.read_only);
    try std.testing.expect(granted.record_filter.flags.live_only);
    try std.testing.expect(granted.record_filter.flags.public_types_only);
    try std.testing.expectError(error.Denied, authorize(&anon, write, &.{}));

    var user = harness.ctx(.{ .user = .{ .id = "u_1" } });
    const full = try authorize(&user, write, &.{});
    try std.testing.expect(!full.read_only);
    try std.testing.expectEqual(@as(?[]const []const u8, null), full.types);

    const setup: Request = .{ .operation_name = "site.init", .kind = .write, .resource = .{} };
    const login: Request = .{
        .operation_name = "user.sign_in",
        .kind = .write,
        .resource = .{},
    };
    try std.testing.expect(!(try authorize(&anon, setup, &.{})).read_only);
    try std.testing.expect(!(try authorize(&anon, login, &.{})).read_only);

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
    try std.testing.expect(!(try authorize(&anon, signup, &.{})).read_only);
    try std.testing.expectError(error.Denied, authorize(&anon, closed, &.{}));
    try std.testing.expectError(error.Denied, authorize(&anon, signup, &.{&deny_all}));

    var editor = harness.ctx(.{ .user = .{ .id = "u_2", .role = .editor } });
    const sign_out: Request = .{
        .operation_name = "user.sign_out",
        .kind = .write,
        .resource = .{},
    };
    try std.testing.expect((try authorize(&editor, sign_out, &.{})).allows());
}

test "delivery narrows any caller to live, read-only records and keeps the caller's own limits" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const read: Request = .{ .operation_name = "record.list", .kind = .read, .resource = .{} };
    const write: Request = .{ .operation_name = "record.save", .kind = .write, .resource = .{} };
    const users_list: Request = .{ .operation_name = "user.list", .kind = .read, .resource = .{} };

    var admin = harness.ctx(.{ .user = .{ .id = "u_1", .role = .admin } });
    admin.delivery = true;
    const granted = try authorize(&admin, read, &.{});
    try std.testing.expect(granted.read_only);
    try std.testing.expect(granted.record_filter.flags.live_only);
    try std.testing.expect(!granted.record_filter.flags.public_types_only);
    try std.testing.expectError(error.Denied, authorize(&admin, write, &.{}));

    var editor = harness.ctx(.{ .user = .{ .id = "u_2", .role = .editor } });
    editor.delivery = true;
    try std.testing.expectError(error.Denied, authorize(&editor, users_list, &.{}));
    try std.testing.expect(!(try authorize(&editor, read, &.{&only_posts})).allows_type("page"));

    var anon = harness.ctx(.anonymous);
    anon.delivery = true;
    const anonymous = try authorize(&anon, read, &.{});
    try std.testing.expect(anonymous.record_filter.flags.public_types_only);
}

test "roles: editors are denied the users and settings namespaces, admins are not" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var editor = harness.ctx(.{ .user = .{ .id = "u_2", .role = .editor } });
    var admin = harness.ctx(.{ .user = .{ .id = "u_1", .role = .admin } });
    const users_list: Request = .{ .operation_name = "user.list", .kind = .read, .resource = .{} };
    const entries_save: Request = .{
        .operation_name = "record.save",
        .kind = .write,
        .resource = .{},
    };

    var anon = harness.ctx(.anonymous);
    try std.testing.expectError(error.Denied, authorize(&editor, users_list, &.{}));
    try std.testing.expectError(error.Denied, authorize(&anon, users_list, &.{}));
    try std.testing.expect((try authorize(&editor, entries_save, &.{})).allows());
    try std.testing.expect((try authorize(&admin, users_list, &.{})).allows());
}

test "plugin policies intersect and can deny" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var user = harness.ctx(.{ .user = .{ .id = "u_1" } });
    const write: Request = .{ .operation_name = "record.save", .kind = .write, .resource = .{} };

    const constrained = try authorize(&user, write, &.{&only_posts});
    try std.testing.expect(constrained.allows_type("post"));
    try std.testing.expect(!constrained.allows_type("page"));

    const denied = authorize(&user, write, &.{ &only_posts, &deny_all });
    try std.testing.expectError(error.Denied, denied);
}

fn only_posts(_: *const Ctx, _: Request) Grant {
    return .{ .types = &.{"post"} };
}

fn deny_all(_: *const Ctx, _: Request) Grant {
    return Grant.deny;
}
