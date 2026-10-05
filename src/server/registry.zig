const std = @import("std");
const sdk = @import("../sdk.zig");
const contract = @import("../sdk/plugin.zig");
const status_registry = @import("../model/status.zig");
const kind_registry = @import("../model/kinds.zig");
const filter_registry = @import("../model/filter.zig");
const role_registry = @import("../model/role.zig");
const heartbeat = @import("../operations/heartbeat.zig");
const project = @import("../operations/project.zig");
const custom_fields = @import("../operations/custom_fields.zig");
const user = @import("../operations/user.zig");
const sign_in = @import("../operations/sign_in.zig");
const sign_on = @import("../operations/sign_on.zig");
const identity = @import("../operations/identity.zig");
const status = @import("../operations/status.zig");
const role = @import("../operations/role.zig");
const content_type = @import("../operations/content_type.zig");
const record = @import("../operations/record.zig");
const taxonomy = @import("../operations/taxonomy.zig");
const term = @import("../operations/term.zig");
const snapshot = @import("../operations/snapshot.zig");
const view = @import("../operations/view.zig");
const internal = @import("../operations/internal.zig");
const plugin_operations = @import("../operations/plugin.zig");
const plugin_types = @import("../sdk/plugin/types.zig");
const plugin_contracts = @import("../model/plugin_contracts.zig");
const shapes = @import("../model/contract.zig");
const activity = @import("../operations/activity.zig");
const errors = @import("../operations/errors.zig");

pub const native_plugins = contract.Merged(@import("native_plugins").all);

const core_operations = heartbeat.operations ++ project.operations ++ custom_fields.operations ++
    user.operations ++
    sign_in.operations ++ sign_on.operations ++ identity.operations ++ status.operations ++
    role.operations ++
    content_type.operations ++
    record.operations ++ taxonomy.operations ++ term.operations ++ snapshot.operations ++
    view.operations ++ plugin_operations.operations ++ internal.operations ++
    activity.operations ++ errors.operations;
const core_namespaces = [_]sdk.operation.Namespace{
    heartbeat.namespace,
    project.namespace,
    custom_fields.namespace,
    user.namespace,
    sign_on.namespace,
    identity.namespace,
    status.namespace,
    role.namespace,
    content_type.namespace,
    record.namespace,
    taxonomy.namespace,
    term.namespace,
    snapshot.namespace,
    view.namespace,
    plugin_operations.namespace,
    internal.namespace,
    activity.namespace,
    errors.namespace,
};

/// The names no plugin may take: every core namespace, `app` (what an app's users call is
/// `app.<plugin>.<verb>`) and `settings`.
pub const reserved_names = [_][]const u8{ "app", "settings" } ++ core_namespace_names;

const core_namespace_names = names: {
    var names: [core_namespaces.len][]const u8 = undefined;

    for (core_namespaces, &names) |namespace, *name| {
        name.* = namespace.name;
    }

    break :names names;
};

comptime {
    for (@import("native_plugins").all) |Plugin| {
        for (reserved_names) |reserved| {
            if (std.mem.eql(u8, Plugin.manifest.name, reserved)) {
                @compileError("plugin " ++ reserved ++ ": the name is core's");
            }
        }
    }
}

/// The internal record collection `kind` of plugin `plugin`, compiled in or installed, if
/// it declared one.
pub fn internal_collection(
    ctx: *const sdk.Ctx,
    plugin: []const u8,
    kind: []const u8,
) ?contract.InternalCollection {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(kind.len > 0);

    for (native_plugins.merged_internal_collections) |owned| {
        const named = std.mem.eql(u8, owned.collection.kind, kind);

        if (named and std.mem.eql(u8, owned.owner, plugin)) {
            return owned.collection;
        }
    }

    const sandboxed = ctx.sandboxed_plugins orelse return null;

    for (sandboxed.manifests()) |manifest| {
        if (std.mem.eql(u8, manifest.name, plugin)) {
            return @import("../model/internal_record.zig").find(manifest.internal_records, kind);
        }
    }

    return null;
}

/// The compiled-in plugins as providers: each operation's shapes, for the contracts of the
/// installed plugins that use them. Each shape is described when the binary compiles, one
/// operation at a time.
pub fn native_providers(
    arena: std.mem.Allocator,
) error{OutOfMemory}![]const plugin_contracts.Provider {
    const plugins = @import("native_plugins").all;
    const list = try arena.alloc(plugin_contracts.Provider, plugins.len);

    std.debug.assert(plugins.len <= 64);

    inline for (plugins, list) |Plugin, *provider| {
        const operations = comptime contract.operations_of(Plugin);
        const provided = try arena.alloc(plugin_contracts.Provided, operations.len);

        inline for (operations, 0..) |Operation, index| {
            provided[index] = .{
                .name = Operation.name,
                .input = comptime shapes.describe(Operation.In),
                .output = comptime shapes.describe(Operation.Out),
            };
        }

        provider.* = .{
            .plugin = Plugin.manifest.name,
            .version = Plugin.manifest.version,
            .operations = provided,
        };
    }

    return list;
}

/// The core's operations and middleware belong to no plugin.
fn core_owners(comptime count: u32) [count][]const u8 {
    return @splat("");
}

pub const registry: sdk.Registry = .{
    .operations = &core_operations ++ native_plugins.merged_operations,
    .namespaces = &core_namespaces ++ native_plugins.merged_namespaces,
    .policies = native_plugins.merged_policies,
    .middleware = &project.middleware ++ native_plugins.merged_middleware,
    .operation_owners = &core_owners(core_operations.len) ++
        native_plugins.merged_operation_owners,
    .middleware_owners = &core_owners(project.middleware.len) ++
        native_plugins.merged_middleware_owners,
    .schemas = native_plugins.merged_schemas,
    .roles = native_plugins.merged_roles,
    .bootstrap = &bootstrap,
    .log = activity.log,
};

pub const SDK = sdk.SDK(registry);

pub const Statuses = status_registry.Registry(
    &status_registry.core_statuses ++ native_plugins.merged_statuses,
    &status_registry.core_transitions ++ native_plugins.merged_transitions,
);

pub const Kinds = kind_registry.Registry(&kind_registry.core ++ native_plugins.merged_field_kinds);

pub const Filters = filter_registry.Registry(
    &filter_registry.core ++ native_plugins.merged_filters,
);

pub const Roles = role_registry.Registry(native_plugins.merged_roles);

/// The sign-in providers the native plugins declare, offered or not.
pub const sign_in_providers = native_plugins.merged_sign_in_providers;
pub const plugin_routes = native_plugins.merged_routes;
pub const settings_pages = native_plugins.merged_settings_pages;
pub const row_actions = native_plugins.merged_row_actions;
pub const top_bar = native_plugins.merged_top_bar;
pub const sign_in_at = native_plugins.merged_sign_in_at;
pub const app_picker_segment = native_plugins.merged_app_picker_segment;
pub const stateful_plugins = native_plugins.merged_stateful;
pub const operator_commands = native_plugins.merged_operator_commands;
pub const before_command = native_plugins.merged_before_command;
pub const serving = native_plugins.merged_serving;

/// Once the schema is applied: the declared types and fields, then each plugin's own
/// `bootstrap`, as the system, in name order.
fn bootstrap(ctx: *sdk.Ctx) sdk.Error!void {
    @import("std").debug.assert(ctx.caller == .system);
    @import("std").debug.assert(ctx.db.transaction_depth == 0);
    try plugin_types.apply_all(ctx);

    inline for (native_plugins.all) |Plugin| {
        if (@hasDecl(Plugin, "bootstrap")) {
            try Plugin.bootstrap(ctx);
        }
    }
}
