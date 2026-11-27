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
    /// The content type the call names (its input's `type`), if any.
    type_id: ?[]const u8 = null,
    /// The operation says anyone may call it (`pub const open = true`), like signing in:
    /// a plugin's own open door, such as creating an account. Policies still narrow it.
    open: bool = false,
    /// The type the call names, when the compiled-in plugin whose code runs declares it:
    /// reached whoever the plugin runs for, as an installed plugin reaches its own.
    own_types: []const []const u8 = &.{},
    /// The grants of the compiled-in plugin whose code makes the call: it gets no more than
    /// they allow, whoever it runs for.
    plugin_access: ?*const plugin_access.Access = null,
};

pub const Policy = public.Policy;

const public = @import("../publr/extend/policy.zig");

/// What a plugin's policy is told of `request` and its caller, and its answer as core's.
fn asked(ctx: *const Ctx, request: Request, policy: Policy) Grant {
    std.debug.assert(request.operation_name.len > 0);

    const caller_view = @import("plugin/caller_view.zig");
    const through_app = ctx.app_plugins != null;
    const who = caller_view.view_of(ctx.caller, .{
        .from = caller_view.from_of(ctx.caller, through_app, ctx.over_api, ctx.job),
        .nested = ctx.within.len > 0,
    });
    const answer = policy(who, .{
        .operation_name = request.operation_name,
        .kind = request.kind,
        .type_id = request.type_id,
        .open = request.open,
        .own_type = request.own_types.len > 0,
        .nested = ctx.within.len > 0,
        .delivery = ctx.delivery,
    });

    std.debug.assert(answer.decision == .allow or answer.decision == .deny);

    return .{
        .decision = if (answer.decision == .allow) .allow else .deny,
        .read_only = answer.read_only,
        .types = answer.types,
        .record_filter = .{
            .flags = .{
                .own_only = answer.own_only,
                .live_only = answer.live_only,
                .public_types_only = answer.public_types_only,
            },
        },
    };
}

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
    .record_filter = .{
        .flags = .{
            .live_only = true,
        },
    },
};

/// What the core allows before any plugin narrows it: anonymous callers read live public
/// records; a signed-in account what its roles grant; the system everything; a plugin what
/// its granted permissions allow.
pub fn core_policy(ctx: *const Ctx, request: Request, roles: []const Role) operation.Error!Grant {
    std.debug.assert(request.operation_name.len > 0);
    std.debug.assert(std.mem.indexOfScalar(u8, request.operation_name, '.') != null);

    // A visitor's order is the shop's to write: the plugin's operation decided it may.
    if (request.own_types.len > 0) {
        return .{
            .types = request.own_types,
        };
    }

    // A plugin's code reaches its own internal records and field groups whoever it runs
    // for: the operations scope every call to `ctx.plugin`, so nothing else is reachable.
    if (ctx.plugin.len > 0 and own_data(request.operation_name)) {
        return Grant.allow_all;
    }

    return switch (ctx.caller) {
        .anonymous => anonymous_grant(request),
        .user => |user| role_grant(roles, user.roles, request),
        .token => |token| device_grant(roles, token, request),
        .plugin => |plugin| if (plugin.access != null)
            try plugin_grant(ctx, request, roles)
        else
            Grant.deny,
        .system => Grant.allow_all,
    };
}

fn own_data(operation_name: []const u8) bool {
    std.debug.assert(operation_name.len > 0);

    // A plugin's made files are its own: each operation checks the part and the type are.
    return std.mem.startsWith(u8, operation_name, "internal.") or
        std.mem.eql(u8, operation_name, "custom_fields.values") or
        std.mem.eql(u8, operation_name, "custom_fields.save_values") or
        std.mem.eql(u8, operation_name, "media.write_part") or
        std.mem.eql(u8, operation_name, "media.make") or
        std.mem.eql(u8, operation_name, "media.made");
}

/// Everything one of the account's roles grants, and the doors open to everyone. Short of
/// a grant, a signed-in account gets what an anonymous visitor gets: live records of public
/// types, so an app's pages read those for its visitors whatever their roles.
fn role_grant(roles: []const Role, held: []const []const u8, request: Request) Grant {
    std.debug.assert(request.operation_name.len > 0);
    std.debug.assert(held.len <= role.user_roles_max);

    if (request.open) {
        return Grant.allow_all;
    }

    if (role.permit(roles, held, request.operation_name)) {
        const admin = for (held) |name| {
            if (std.mem.eql(u8, name, role.admin)) {
                break true;
            }
        } else false;

        // A Private type with a role list reaches its roles; administrators every type.
        return .{
            .roles = if (admin) null else held,
        };
    }

    return anonymous_grant(request);
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
    if (request.open) {
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
        .record_filter = .{
            .flags = .{
                .live_only = true,
                .public_types_only = true,
            },
        },
    };

    std.debug.assert(granted.allows());
    std.debug.assert(granted.read_only);

    return granted;
}

/// What the device's account may, narrowed by its scope: a `read` device reads only. What
/// a device short of `publish` may not do (publish) is known only once the write ran
/// (`SDK.check_drafts`).
fn device_grant(roles: []const Role, token: caller_module.Caller.Token, request: Request) Grant {
    std.debug.assert(request.operation_name.len > 0);
    std.debug.assert(token.user_id.len > 0);

    var granted = role_grant(roles, token.roles, request);

    if (token.scope == .read and granted.allows()) {
        granted.read_only = true;
    }

    return granted;
}

/// An installed plugin's grant, narrowed to the roles of the account it acts for, if any.
fn plugin_grant(ctx: *const Ctx, request: Request, roles: []const Role) operation.Error!Grant {
    const plugin = ctx.caller.plugin;
    const access = plugin.access.?;

    std.debug.assert(request.operation_name.len > 0);
    std.debug.assert(plugin.name.len > 0);

    const granted = try plugin_access.grant(ctx.arena, plugin.name, access, .{
        .operation_name = request.operation_name,
        .type_id = request.type_id,
    });
    const held = plugin.roles orelse return granted;

    // Its own types' records are its own business whoever it acts for: a visitor's account,
    // holding none of the admin's roles, still has its order made.
    if (own_records(access, request)) {
        return granted;
    }

    const narrowed = try Grant.intersect(granted, role_grant(roles, held, request), ctx.arena);

    // A query names no type ahead: what the account may not read, the plugin still reads of
    // its own types (an order it just placed for a customer) and of the types its own
    // `records.read` names (a plugin it requires), and nothing else: a wide read stays on its
    // own types.
    if (!narrowed.allows() and granted.allows() and own_query(access, request)) {
        var own = granted;

        own.types = granted.types orelse access.own_types;

        return own;
    }

    return narrowed;
}

/// Whether the request is a query (GROQ) by a plugin that has types of its own.
fn own_query(access: *const plugin_access.Access, request: Request) bool {
    std.debug.assert(request.operation_name.len > 0);

    return request.type_id == null and access.own_types.len > 0 and
        std.mem.eql(u8, request.operation_name, "record.query");
}

/// Whether the request is a record operation on one of the plugin's own types.
fn own_records(access: *const plugin_access.Access, request: Request) bool {
    std.debug.assert(request.operation_name.len > 0);

    const type_id = request.type_id orelse return false;
    const permission = @import("../model/permission.zig");

    std.debug.assert(type_id.len > 0);

    return permission.contains(access.own_types, type_id) and
        permission.contains(&permission.own_records, request.operation_name);
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

    // A compiled-in plugin is held to its grants for what a permission names; what none
    // names (its own seams into core, other plugins' operations) stays as its build made it.
    if (request.plugin_access) |access| {
        if (result.allows() and plugin_access.names_operation(request.operation_name)) {
            std.debug.assert(ctx.plugin.len > 0);

            const held = try plugin_access.grant(ctx.arena, ctx.plugin, access, .{
                .operation_name = request.operation_name,
                .type_id = request.type_id,
            });

            result = try Grant.intersect(result, held, ctx.arena);
        }
    }

    for (policies) |policy| {
        if (!result.allows()) {
            break;
        }
        result = try Grant.intersect(result, asked(ctx, request, policy), ctx.arena);
    }

    if (ctx.delivery and result.allows()) {
        result = try Grant.intersect(result, delivery_grant, ctx.arena);
    }

    if (ctx.preview and result.allows()) {
        result = try Grant.intersect(result, .{
            .read_only = true,
        }, ctx.arena);
    }

    // An app reaches the plugins it lists, and the providers of the contracts they own.
    if (ctx.app_plugins) |plugins| {
        if (result.allows()) {
            result = try Grant.intersect(result, .{
                .plugins = try @import("contract.zig").with_providers(ctx, plugins),
            }, ctx.arena);
        }
    }

    if (ctx.app_reach.len > 0 and result.allows()) {
        result = try Grant.intersect(result, .{
            .app = ctx.app_reach,
        }, ctx.arena);
    }

    if (!result.allows()) {
        return error.Denied;
    }

    if (result.read_only and request.kind == .write) {
        return error.Denied;
    }

    return result;
}

test "core policy: a plugin's own type is reached whoever it runs for, only that type" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var anon = harness.ctx(.anonymous);
    const create: Request = .{
        .operation_name = "record.create",
        .kind = .write,
        .type_id = "order",
        .own_types = &.{"order"},
    };
    const granted = try authorize(&anon, create, &.{}, &role.core);

    try std.testing.expect(!granted.read_only);
    try std.testing.expect(granted.allows_type("order"));
    try std.testing.expect(!granted.allows_type("post"));

    var not_own = create;
    not_own.own_types = &.{};

    try std.testing.expectError(error.Denied, authorize(&anon, not_own, &.{}, &role.core));
}

test "an installed plugin acting for a visitor's account queries its own types, only those" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const access: plugin_access.Access = .{
        .held = &.{},
        .own_types = &.{"order"},
    };
    var acting = harness.ctx(.{
        .plugin = .{
            .name = "orders",
            .access = &access,
            .roles = &.{"customer"},
        },
    });

    acting.plugin = "orders";

    const query: Request = .{
        .operation_name = "record.query",
        .kind = .read,
        .plugin_access = &access,
    };
    const granted = try authorize(&acting, query, &.{}, &role.core);

    try std.testing.expect(granted.allows_type("order"));
    try std.testing.expect(!granted.allows_type("post"));
}

test "an installed plugin acting for a visitor's account queries what its records.read names" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const held = [_]@import("../model/permission.zig").Held{.{
        .key = "records.read",
        .records = &.{"orders.order"},
    }};
    const access: plugin_access.Access = .{
        .held = &held,
        .own_types = &.{"payments.payment"},
    };
    var acting = harness.ctx(.{
        .plugin = .{
            .name = "payments",
            .access = &access,
            .roles = &.{"customer"},
        },
    });

    acting.plugin = "payments";

    const query: Request = .{
        .operation_name = "record.query",
        .kind = .read,
        .plugin_access = &access,
    };
    const named = try authorize(&acting, query, &.{}, &role.core);

    // The type of the plugin it requires stays in reach, beside its own; nothing else.
    try std.testing.expect(named.allows_type("payments.payment"));
    try std.testing.expect(named.allows_type("orders.order"));
    try std.testing.expect(!named.allows_type("post"));
}

test "a compiled-in plugin's code is held to its grants, queued work included" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const held = [_]@import("../model/permission.zig").Held{.{
        .key = "records.write",
        .records = &.{"note"},
    }};
    const access: plugin_access.Access = .{
        .held = &held,
        .own_types = &.{},
    };
    // A job runs as the system, its plugin's code still held to the plugin's grant.
    var queued = harness.ctx(.system);

    queued.plugin = "prices";

    var save: Request = .{
        .operation_name = "record.save",
        .kind = .write,
        .type_id = "note",
        .plugin_access = &access,
    };
    const granted = try authorize(&queued, save, &.{}, &role.core);

    try std.testing.expect(granted.allows_type("note"));

    save.type_id = "post";
    try std.testing.expectError(error.Denied, authorize(&queued, save, &.{}, &role.core));

    const publish: Request = .{
        .operation_name = "record.publish",
        .kind = .write,
        .type_id = "note",
        .plugin_access = &access,
    };

    try std.testing.expectError(error.Denied, authorize(&queued, publish, &.{}, &role.core));

    // What no permission names stays as the build made it.
    _ = try authorize(&queued, .{
        .operation_name = "rail.pin",
        .kind = .write,
        .plugin_access = &access,
    }, &.{}, &role.core);
}

test "core policy: anonymous reads live+public only, writes denied; users and system full" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const read: Request = .{
        .operation_name = "record.get",
        .kind = .read,
    };
    const write: Request = .{
        .operation_name = "record.save",
        .kind = .write,
    };

    var anon = harness.ctx(.anonymous);
    const granted = try authorize(&anon, read, &.{}, &role.core);
    try std.testing.expect(granted.read_only);
    try std.testing.expect(granted.record_filter.flags.live_only);
    try std.testing.expect(granted.record_filter.flags.public_types_only);
    try std.testing.expectError(error.Denied, authorize(&anon, write, &.{}, &role.core));

    var user = harness.ctx(.{
        .user = .{
            .id = "u_1",
        },
    });
    const full = try authorize(&user, write, &.{}, &role.core);
    try std.testing.expect(!full.read_only);
    try std.testing.expectEqual(@as(?[]const []const u8, null), full.types);

    const setup: Request = .{
        .operation_name = "project.init",
        .kind = .write,
        .open = true,
    };
    const login: Request = .{
        .operation_name = "user.sign_in",
        .kind = .write,
        .open = true,
    };
    try std.testing.expect(!(try authorize(&anon, setup, &.{}, &role.core)).read_only);
    try std.testing.expect(!(try authorize(&anon, login, &.{}, &role.core)).read_only);

    const signup: Request = .{
        .operation_name = "plugin.sign_up",
        .kind = .write,
        .open = true,
    };
    const closed: Request = .{
        .operation_name = "plugin.sign_up",
        .kind = .write,
    };
    try std.testing.expect(!(try authorize(&anon, signup, &.{}, &role.core)).read_only);
    try std.testing.expectError(error.Denied, authorize(&anon, closed, &.{}, &role.core));
    try std.testing.expectError(error.Denied, authorize(&anon, signup, &.{&deny_all}, &role.core));

    var editor = harness.ctx(.{
        .user = .{
            .id = "u_2",
            .roles = &.{"editor"},
        },
    });
    const sign_out: Request = .{
        .operation_name = "user.sign_out",
        .kind = .write,
        .open = true,
    };
    try std.testing.expect((try authorize(&editor, sign_out, &.{}, &role.core)).allows());
}

test "delivery narrows any caller to live, read-only records and keeps the caller's own limits" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const read: Request = .{
        .operation_name = "record.list",
        .kind = .read,
    };
    const write: Request = .{
        .operation_name = "record.save",
        .kind = .write,
    };
    const users_list: Request = .{
        .operation_name = "user.list",
        .kind = .read,
    };

    var admin = harness.ctx(.{
        .user = .{
            .id = "u_1",
            .roles = &.{"admin"},
        },
    });
    admin.delivery = true;
    const granted = try authorize(&admin, read, &.{}, &role.core);
    try std.testing.expect(granted.read_only);
    try std.testing.expect(granted.record_filter.flags.live_only);
    try std.testing.expect(!granted.record_filter.flags.public_types_only);
    try std.testing.expectError(error.Denied, authorize(&admin, write, &.{}, &role.core));

    var editor = harness.ctx(.{
        .user = .{
            .id = "u_2",
            .roles = &.{"editor"},
        },
    });
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

    var editor = harness.ctx(.{
        .user = .{
            .id = "u_2",
            .roles = &.{"editor"},
        },
    });
    var admin = harness.ctx(.{
        .user = .{
            .id = "u_1",
            .roles = &.{"admin"},
        },
    });
    const users_list: Request = .{
        .operation_name = "user.list",
        .kind = .read,
    };
    const entries_save: Request = .{
        .operation_name = "record.save",
        .kind = .write,
    };

    var anon = harness.ctx(.anonymous);
    try std.testing.expectError(error.Denied, authorize(&editor, users_list, &.{}, &role.core));
    try std.testing.expectError(error.Denied, authorize(&anon, users_list, &.{}, &role.core));
    try std.testing.expect((try authorize(&editor, entries_save, &.{}, &role.core)).allows());
    try std.testing.expect((try authorize(&admin, users_list, &.{}, &role.core)).allows());
}

test "devices: their account's roles, a read device reads only" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const save: Request = .{
        .operation_name = "record.save",
        .kind = .write,
    };
    const users_list: Request = .{
        .operation_name = "user.list",
        .kind = .read,
    };
    const editor_roles: []const []const u8 = &.{"editor"};

    var writer = harness.ctx(.{
        .token = .{
            .id = "d_1",
            .user_id = "u_1",
            .roles = editor_roles,
            .scope = .publish,
        },
    });
    try std.testing.expect((try authorize(&writer, save, &.{}, &role.core)).allows());
    try std.testing.expectError(error.Denied, authorize(&writer, users_list, &.{}, &role.core));

    var reader = harness.ctx(.{
        .token = .{
            .id = "d_2",
            .user_id = "u_1",
            .roles = &.{"admin"},
            .scope = .read,
        },
    });
    try std.testing.expectError(error.Denied, authorize(&reader, save, &.{}, &role.core));
    try std.testing.expect((try authorize(&reader, users_list, &.{}, &role.core)).allows());
}

test "plugin policies intersect and can deny" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var user = harness.ctx(.{
        .user = .{
            .id = "u_1",
        },
    });
    const write: Request = .{
        .operation_name = "record.save",
        .kind = .write,
    };

    const constrained = try authorize(&user, write, &.{&only_posts}, &role.core);
    try std.testing.expect(constrained.allows_type("post"));
    try std.testing.expect(!constrained.allows_type("page"));

    const denied = authorize(&user, write, &.{ &only_posts, &deny_all }, &role.core);
    try std.testing.expectError(error.Denied, denied);
}

fn only_posts(_: public.View, _: public.Request) public.Grant {
    return .{
        .types = &.{"post"},
    };
}

fn deny_all(_: public.View, _: public.Request) public.Grant {
    return public.Grant.deny;
}
