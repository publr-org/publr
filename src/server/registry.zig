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
const plugin_operations = @import("../operations/plugin.zig");
const plugin_types = @import("../sdk/plugin/types.zig");

pub const native_plugins = contract.Merged(@import("native_plugins").all);

const core_operations = heartbeat.operations ++ project.operations ++ custom_fields.operations ++
    user.operations ++
    sign_in.operations ++ sign_on.operations ++ identity.operations ++ status.operations ++
    role.operations ++
    content_type.operations ++
    record.operations ++ taxonomy.operations ++ term.operations ++ snapshot.operations ++
    view.operations ++ plugin_operations.operations;
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
};

pub const registry: sdk.Registry = .{
    .operations = &core_operations ++ native_plugins.merged_operations,
    .namespaces = &core_namespaces ++ native_plugins.merged_namespaces,
    .policies = native_plugins.merged_policies,
    .middleware = &project.middleware ++ native_plugins.merged_middleware,
    .schemas = native_plugins.merged_schemas,
    .roles = native_plugins.merged_roles,
    .bootstrap = &bootstrap,
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
