//! What an installed plugin may call: the permissions an administrator granted it, turned into
//! the grant `authorize` returns. One function over data, so every call a plugin makes is
//! decided the same way.
const std = @import("std");
const permission = @import("../model/permission.zig");
const operation = @import("operation.zig");
const Grant = @import("grant.zig").Grant;
const plugin_depends_on = @import("plugin/depends_on.zig");

pub const Access = struct {
    /// The permission keys granted now; revoking one takes effect on the next call.
    granted: []const []const u8,
    /// The content types the plugin declared: always its own.
    own_types: []const []const u8,
    /// The content types its content permissions reach besides its own: null for every type.
    types: ?[]const []const u8,
    catalog: []const permission.Permission = &permission.core,
    /// The plugins it declares it depends on: the only ones whose operations a `call:`
    /// grant reaches.
    depends_on: []const []const u8 = &.{},
    /// The plugins it works with when present: a `call:` grant reaches these too.
    compatible_with: []const []const u8 = &.{},

    pub fn has(access: *const Access, key: []const u8) bool {
        std.debug.assert(key.len > 0);
        std.debug.assert(access.granted.len <= permission.operations_max * 4);

        return permission.contains(access.granted, key);
    }
};

pub const Request = struct {
    operation_name: []const u8,
    kind: operation.Kind,
    type_id: ?[]const u8 = null,
};

/// The grant a plugin `name` holds for one request. Its own namespace and the harmless
/// operations need nothing; its own content types' records need nothing; everything else
/// needs a granted permission naming the operation, held to the content access.
pub fn grant(name: []const u8, access: *const Access, request: Request) Grant {
    std.debug.assert(name.len > 0);
    std.debug.assert(request.operation_name.len > 0);

    const operation_name = request.operation_name;

    if (permission.contains(&permission.never, operation_name)) {
        return Grant.deny;
    }

    if (permission.contains(&permission.always, operation_name) or own(name, operation_name)) {
        return Grant.allow_all;
    }

    if (calls_dependency(access, operation_name)) {
        return Grant.allow_all;
    }

    const own_type = if (request.type_id) |type_id|
        permission.contains(access.own_types, type_id)
    else
        false;
    const own_record = permission.contains(&permission.own_records, operation_name);

    if (own_record and own_type) {
        return .{ .types = access.own_types };
    }

    // Without a permission, a record operation still reaches the plugin's own types; one
    // that names another type is refused here rather than by the operation.
    const keyed = granting(access, operation_name) orelse {
        const unnamed = request.type_id == null;

        return if (own_record and unnamed) .{ .types = access.own_types } else Grant.deny;
    };

    if (!keyed.content) {
        return Grant.allow_all;
    }

    var granted: Grant = .{ .types = access.types };

    if (request.kind == .read and !access.has("content.drafts")) {
        granted.record_filter.flags.live_only = true;
    }

    return granted;
}

/// Whether `operation_name` is in the plugin's own namespace: `<name>.*`, `app.<name>.*`.
pub fn own(name: []const u8, operation_name: []const u8) bool {
    std.debug.assert(name.len > 0);
    std.debug.assert(operation_name.len > 0);

    const namespace = operation.namespace(operation_name);
    const app_namespace = std.mem.startsWith(u8, namespace, "app.") and
        std.mem.eql(u8, namespace[4..], name);

    return std.mem.eql(u8, namespace, name) or app_namespace;
}

/// Whether a granted `call:` permission names exactly this operation of a plugin it depends
/// on. A dependency alone grants nothing, and neither does a grant without one.
fn calls_dependency(access: *const Access, operation_name: []const u8) bool {
    std.debug.assert(operation_name.len > 0);
    std.debug.assert(access.depends_on.len <= plugin_depends_on.depends_on_max);

    for (access.granted) |key| {
        const target = permission.called_operation(key) orelse continue;

        if (!std.mem.eql(u8, target, operation_name)) {
            continue;
        }

        for ([_][]const []const u8{ access.depends_on, access.compatible_with }) |list| {
            if (names_owner(list, operation_name)) {
                return true;
            }
        }
    }

    return false;
}

fn names_owner(list: []const []const u8, operation_name: []const u8) bool {
    std.debug.assert(operation_name.len > 0);
    std.debug.assert(list.len <= plugin_depends_on.depends_on_max * 2);

    for (list) |text| {
        const parent = if (text.len > 0) plugin_depends_on.parse(text).name else "";

        if (parent.len > 0 and own(parent, operation_name)) {
            return true;
        }
    }

    return false;
}

/// The granted permission that names the operation, if any.
fn granting(access: *const Access, operation_name: []const u8) ?*const permission.Permission {
    std.debug.assert(operation_name.len > 0);
    std.debug.assert(access.catalog.len > 0);

    for (access.granted) |key| {
        const found = permission.find(access.catalog, key) orelse continue;

        if (permission.contains(found.operations, operation_name)) {
            return found;
        }
    }

    return null;
}

test "own namespace and harmless calls need nothing; never is never" {
    const access: Access = .{ .granted = &.{}, .own_types = &.{"greeting"}, .types = null };

    try std.testing.expect(grant("greeter", &access, .{
        .operation_name = "greeter.greet",
        .kind = .write,
    }).allows());
    try std.testing.expect(grant("greeter", &access, .{
        .operation_name = "app.greeter.join",
        .kind = .write,
    }).allows());
    try std.testing.expect(grant("greeter", &access, .{
        .operation_name = "heartbeat.check",
        .kind = .read,
    }).allows());
    try std.testing.expect(!grant("greeter", &access, .{
        .operation_name = "user.list",
        .kind = .read,
    }).allows());

    const everything: Access = .{
        .granted = &.{ "users.read", "users.write" },
        .own_types = &.{},
        .types = null,
    };

    try std.testing.expect(!grant("greeter", &everything, .{
        .operation_name = "user.password_link",
        .kind = .write,
    }).allows());
    try std.testing.expect(grant("greeter", &everything, .{
        .operation_name = "user.list",
        .kind = .read,
    }).allows());
}

test "records: own types without asking, others through content permissions and access" {
    const bare: Access = .{ .granted = &.{}, .own_types = &.{"greeting"}, .types = &.{"post"} };
    const own_list = grant("greeter", &bare, .{
        .operation_name = "record.list",
        .kind = .read,
        .type_id = "greeting",
    });

    try std.testing.expect(own_list.allows());
    try std.testing.expect(own_list.allows_type("greeting"));
    try std.testing.expect(!own_list.allows_type("post"));
    try std.testing.expect(!own_list.record_filter.flags.live_only);

    const reader: Access = .{
        .granted = &.{"content.read"},
        .own_types = &.{"greeting"},
        .types = &.{ "greeting", "post" },
    };
    const posts = grant("greeter", &reader, .{ .operation_name = "record.list", .kind = .read });

    try std.testing.expect(posts.allows_type("post"));
    try std.testing.expect(!posts.allows_type("page"));
    try std.testing.expect(posts.record_filter.flags.live_only);
    try std.testing.expect(grant("greeter", &reader, .{
        .operation_name = "record.referrers",
        .kind = .read,
        .type_id = "greeting",
    }).record_filter.flags.live_only);

    const writer: Access = .{
        .granted = &.{ "content.write", "content.drafts" },
        .own_types = &.{},
        .types = null,
    };

    try std.testing.expect(grant("greeter", &writer, .{
        .operation_name = "record.save",
        .kind = .write,
    }).allows_type("anything"));
    try std.testing.expect(!grant("greeter", &writer, .{
        .operation_name = "record.purge",
        .kind = .write,
        .type_id = "post",
    }).allows());
}

test "an exact plugin call needs both its grant and a declared parent" {
    var access: Access = .{
        .granted = &.{"call:app.provider.adjust"},
        .own_types = &.{},
        .types = &.{},
    };
    const request: Request = .{ .operation_name = "app.provider.adjust", .kind = .write };
    try std.testing.expect(!grant("child", &access, request).allows());
    access.depends_on = &.{"provider@^0.3"};
    try std.testing.expect(grant("child", &access, request).allows());
    try std.testing.expect(!grant("child", &access, .{
        .operation_name = "app.provider.purge",
        .kind = .write,
    }).allows());

    access.granted = &.{"call:provider.adjust"};
    try std.testing.expect(grant("child", &access, .{
        .operation_name = "provider.adjust",
        .kind = .write,
    }).allows());
    try std.testing.expect(!grant("child", &access, request).allows());

    access.granted = &.{};
    try std.testing.expect(!grant("child", &access, request).allows());
}
