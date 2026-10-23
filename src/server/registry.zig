const std = @import("std");
const plugin_define = @import("../sdk/plugin/define.zig");
const sdk = @import("../sdk.zig");
const db = @import("../lib/db.zig");
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
const device = @import("../operations/device.zig");
const apps = @import("../operations/apps.zig");
const removal = @import("../operations/removal.zig");
const trash = @import("../operations/trash.zig");
const identity = @import("../operations/identity.zig");
const status = @import("../operations/status.zig");
const flow_operations = @import("../operations/flow.zig");
const job = @import("../operations/job.zig");
const webhook = @import("../operations/webhook.zig");
const role = @import("../operations/role.zig");
const content_type = @import("../operations/content_type.zig");
const record = @import("../operations/record.zig");
const taxonomy = @import("../operations/taxonomy.zig");
const term = @import("../operations/term.zig");
const media = @import("../operations/media.zig");
const snapshot = @import("../operations/snapshot.zig");
const view = @import("../operations/view.zig");
const rail = @import("../operations/rail.zig");
const internal = @import("../operations/internal.zig");
const plugin_operations = @import("../operations/plugin.zig");
const plugin_lifecycle = @import("../operations/plugin/lifecycle.zig");
const plugin_types = @import("../sdk/plugin/types.zig");
const plugin_contracts = @import("../model/plugin_contracts.zig");
const remote_contract = @import("../sdk/plugin/remote_contract.zig");
const shapes = @import("../model/contract.zig");
const activity = @import("../operations/activity.zig");
const errors = @import("../operations/errors.zig");
const ai = @import("../operations/ai.zig");
const secret = @import("../operations/secret.zig");
const http_operations = @import("../operations/http.zig");
const update = @import("../operations/update.zig");
const design_operations = @import("../operations/design.zig");
const health = @import("../operations/health.zig");
const operation_operations = @import("../operations/operation.zig");
const mod_operations = @import("../operations/mod.zig");
const provider_operations = @import("../operations/provider.zig");
const messaging = @import("../sdk/messaging.zig");

/// The compiled-in plugins, each bound to its doc comments.
pub const bound_plugins = bound: {
    const listed = @import("native_plugins");
    var types: [listed.all.len]type = undefined;

    for (listed.all, listed.docs, &types) |Module, Docs, *slot| {
        slot.* = plugin_define.Bind(Module, Docs);
    }

    break :bound types;
};

pub const native_plugins = contract.Merged(bound_plugins);

/// The compiled-in plugins' remotes another compiled-in plugin switches off, and why: off
/// from the start, their hooks left out of the build.
pub const remotes_off = native_plugins.merged_remotes_off;

const core_operations = heartbeat.operations ++ project.operations ++ custom_fields.operations ++
    user.operations ++
    sign_in.operations ++ sign_on.operations ++ device.operations ++ identity.operations ++
    status.operations ++ flow_operations.operations ++ job.operations ++ webhook.operations ++
    role.operations ++
    content_type.operations ++
    record.operations ++ taxonomy.operations ++ term.operations ++ media.operations ++
    snapshot.operations ++
    view.operations ++ rail.operations ++ plugin_operations.operations ++ internal.operations ++
    activity.operations ++ errors.operations ++ apps.operations ++ ai.operations ++
    secret.operations ++ http_operations.operations ++ update.operations ++
    removal.operations ++ trash.operations ++ design_operations.operations ++
    health.operations ++ operation_operations.operations ++ mod_operations.operations ++
    provider_operations.operations;
const core_namespaces = [_]sdk.operation.Namespace{
    heartbeat.namespace,
    project.namespace,
    custom_fields.namespace,
    user.namespace,
    sign_on.namespace,
    device.namespace,
    identity.namespace,
    status.namespace,
    flow_operations.namespace,
    job.namespace,
    webhook.namespace,
    operation_operations.namespace,
    mod_operations.namespace,
    role.namespace,
    content_type.namespace,
    record.namespace,
    taxonomy.namespace,
    term.namespace,
    media.namespace,
    snapshot.namespace,
    view.namespace,
    rail.namespace,
    plugin_operations.namespace,
    internal.namespace,
    activity.namespace,
    errors.namespace,
    apps.namespace,
    ai.namespace,
    secret.namespace,
    http_operations.namespace,
    update.namespace,
    removal.namespace,
    trash.namespace,
    design_operations.namespace,
    health.namespace,
    provider_operations.namespace,
};

/// The names no plugin may take: every core namespace, `app` (what an app's users call is
/// `app.<plugin>.<verb>`) and `settings`.
pub const reserved_names = [_][]const u8{ "app", "settings", role_registry.owner_core } ++
    core_namespace_names;

const core_namespace_names = names: {
    var names: [core_namespaces.len][]const u8 = undefined;

    for (core_namespaces, &names) |namespace, *name| {
        name.* = namespace.name;
    }

    break :names names;
};

comptime {
    // Each name against each plugin's, a byte at a time.
    @setEvalBranchQuota(1000 + bound_plugins.len * reserved_names.len * contract.name_len_max);

    for (bound_plugins) |Plugin| {
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

/// Every internal record collection, compiled in and installed, with the plugin keeping it.
pub fn internal_collections(
    ctx: *const sdk.Ctx,
    arena: std.mem.Allocator,
) error{OutOfMemory}![]const contract.OwnedCollection {
    var all: std.ArrayList(contract.OwnedCollection) = .empty;

    try all.appendSlice(arena, native_plugins.merged_internal_collections);

    const sandboxed = ctx.sandboxed_plugins orelse return all.items;

    for (sandboxed.manifests()) |manifest| {
        for (manifest.internal_records) |collection| {
            try all.append(arena, .{
                .owner = manifest.name,
                .collection = collection,
            });
        }
    }

    return all.items;
}

/// An operation's shapes as declarations of their own, so each is described on its own when
/// the binary compiles, whatever else is.
fn Shapes(comptime Operation: type) type {
    return struct {
        pub const input = shapes.describe(Operation.In);
        pub const output = shapes.describe(Operation.Out);
    };
}

/// The compiled-in plugins as providers: each operation's shapes, for the contracts of the
/// installed plugins that use them. Each shape is described when the binary compiles, one
/// operation at a time.
pub fn native_providers(
    arena: std.mem.Allocator,
) error{OutOfMemory}![]const plugin_contracts.Provider {
    const plugins = bound_plugins;
    const list = try arena.alloc(plugin_contracts.Provider, plugins.len);

    std.debug.assert(plugins.len <= 64);

    // Unrolled: a few branches a plugin, and a few an operation.
    @setEvalBranchQuota(1000 + plugins.len * 64 + sdk.operations_max * 8);

    inline for (plugins, list) |Plugin, *provider| {
        const operations = comptime operations: {
            const options = std.meta.fields(@TypeOf(Plugin.options)).len;

            // Each of its options' names against the option and seam names, a byte at a time.
            @setEvalBranchQuota(1000 + options * 64 * 64);

            break :operations plugin_define.get(Plugin, "operations");
        };
        const provided = try arena.alloc(plugin_contracts.Provided, operations.len);

        inline for (operations, 0..) |Operation, index| {
            provided[index] = .{
                .name = Operation.name,
                .input = Shapes(Operation).input,
                .output = Shapes(Operation).output,
            };
        }

        provider.* = .{
            .plugin = Plugin.manifest.name,
            .version = Plugin.manifest.version,
            .operations = provided,
            .records = comptime remote_contract.records_of(Plugin),
            .events = comptime remote_contract.events_of(Plugin),
        };
    }

    return list;
}

/// The compiled-in plugins that use others, each as a user: what the server checks against
/// the installed plugins they name.
pub fn native_users() []const plugin_contracts.User {
    comptime std.debug.assert(bound_plugins.len <= 64);

    return comptime users: {
        var list: []const plugin_contracts.User = &.{};

        // Each plugin's `remotes` looked up against the option and seam names, a byte at a time.
        @setEvalBranchQuota(1000 + bound_plugins.len * 64 * 64);

        for (bound_plugins) |Plugin| {
            const using = remote_contract.user_of(Plugin);

            if (using.remotes.len > 0) {
                list = list ++ &[_]plugin_contracts.User{using};
            }
        }

        break :users list;
    };
}

fn type_owners(comptime declared: anytype) [declared.len]sdk.TypeOwner {
    comptime std.debug.assert(declared.len <= 64 * 64);

    var owners: [declared.len]sdk.TypeOwner = undefined;

    for (declared, &owners) |each, *owner| {
        owner.* = .{
            .handle = each.def.handle,
            .owner = each.owner,
        };
    }

    return owners;
}

/// The core's operations and middleware belong to no plugin.
fn core_owners(comptime count: u32) [count][]const u8 {
    return @splat("");
}

pub const registry: sdk.Registry = .{
    .operations = &core_operations ++ native_plugins.merged_operations,
    .namespaces = &core_namespaces ++ native_plugins.merged_namespaces,
    .policies = native_plugins.merged_policies,
    .hooks = &project.hooks ++ messaging.hooks ++
        native_plugins.merged_hooks,
    .operation_owners = &core_owners(core_operations.len) ++
        native_plugins.merged_operation_owners,
    .hook_owners = &core_owners(project.hooks.len + messaging.hooks.len) ++
        native_plugins.merged_hook_owners,
    .jobs = native_plugins.merged_jobs,
    .job_owners = native_plugins.merged_job_owners,
    .type_owners = &type_owners(native_plugins.merged_content_types),
    .plugin_grants = native_plugins.merged_plugin_grants,
    .schemas = native_plugins.merged_schemas,
    .migrations = &db.migrations.core,
    .bootstrap = &bootstrap,
    .log = activity.log,
    .removal = removal.prepare,
    .core_job = job.run_core,
};

pub const SDK = sdk.SDK(registry);

pub const Kinds = kind_registry.Registry(&kind_registry.core ++ native_plugins.merged_field_kinds);

/// The kinds the project knows: the build's, then its installed plugins' (`with_kinds`),
/// as the context carries them.
pub fn kinds(ctx: *const sdk.Ctx) []const kind_registry.Kind {
    std.debug.assert(ctx.now_ms >= 0);

    if (ctx.kinds) |known| {
        return known;
    }

    const sandboxed = ctx.sandboxed_plugins orelse return Kinds.all;

    return sandboxed.kinds() orelse Kinds.all;
}

pub fn find_kind(ctx: *const sdk.Ctx, id: []const u8) ?kind_registry.Kind {
    return kind_registry.find(kinds(ctx), id);
}

/// The kinds `known` and those `manifests` bring, each under its plugin's name: one already
/// known, or past the most a project holds, is left out and logged.
pub fn with_kinds(
    arena: std.mem.Allocator,
    known: []const kind_registry.Kind,
    manifests: []const model_sandboxed_plugin.Manifest,
) error{OutOfMemory}![]const kind_registry.Kind {
    std.debug.assert(known.len > 0);

    var list: std.ArrayList(kind_registry.Kind) = .empty;

    try list.appendSlice(arena, known);

    for (manifests) |manifest| {
        for (manifest.field_kinds) |declared| {
            const id = try std.fmt.allocPrint(arena, "{s}.{s}", .{ manifest.name, declared.name });
            const fits = id.len <= kind_registry.id_len_max and
                list.items.len < kind_registry.kinds_max and
                kind_registry.find(list.items, id) == null;

            if (!fits) {
                std.log.warn("plugins: the field kind {s} is left out", .{id});
                continue;
            }

            try list.append(arena, field_kind_define.installed(id, declared));
        }
    }

    return if (list.items.len == known.len) known else list.items;
}

const model_sandboxed_plugin = @import("../model/sandboxed_plugin.zig");
const field_kind_define = @import("../sdk/plugin/field_kind_define.zig");
/// The location rules compiled-in plugins bring (`loyalty.tier`).
pub const location_rules = native_plugins.merged_location_rules;

/// Every plugin's location rules: compiled-in plugins', then the installed ones' from their
/// manifests, run in the sandbox.
pub fn all_location_rules(ctx: *const sdk.Ctx) error{OutOfMemory}![]const PluginRule {
    std.debug.assert(ctx.now_ms >= 0);

    const sandboxed = ctx.sandboxed_plugins orelse return location_rules;
    var list: std.ArrayList(PluginRule) = .empty;

    try list.appendSlice(ctx.arena, location_rules);

    for (sandboxed.manifests()) |manifest| {
        for (manifest.location_rules) |rule| {
            const id = try std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ manifest.name, rule.name });

            try list.append(ctx.arena, location_rule_define.installed(id, rule.label));
        }
    }

    return list.items;
}

const PluginRule = @import("../model/field_group.zig").PluginRule;
const location_rule_define = @import("../sdk/plugin/location_rule_define.zig");
/// The columns compiled-in plugins add to lists they don't own.
pub const columns = native_plugins.merged_columns;

/// Every plugin's columns on lists it doesn't own: compiled-in plugins', then the installed
/// ones' from their manifests.
pub fn all_columns(ctx: *const sdk.Ctx) error{OutOfMemory}![]const Column {
    std.debug.assert(ctx.now_ms >= 0);

    const sandboxed = ctx.sandboxed_plugins orelse return columns;
    var list: std.ArrayList(Column) = .empty;

    try list.appendSlice(ctx.arena, columns);

    for (sandboxed.manifests()) |manifest| {
        for (manifest.columns) |column| {
            const own = std.mem.startsWith(u8, column.field, manifest.name) and
                column.field.len > manifest.name.len + 1 and
                column.field[manifest.name.len] == '.';

            if (!own or column.list.len == 0) {
                continue;
            }

            try list.append(ctx.arena, .{
                .plugin = manifest.name,
                .list = column.list,
                .field = column.field,
                .label = column.label,
                .kind = column.kind,
                .stored = column.stored,
            });
        }
    }

    return list.items;
}

pub const Column = @import("../sdk/plugin/column_define.zig").Column;

pub const Filters = filter_registry.Registry(&filter_registry.core);

/// The webhooks the native plugins declare, and the plugin of each.
pub const webhooks = native_plugins.merged_webhooks;
pub const webhook_owners = native_plugins.merged_webhook_owners;
/// The sign-in providers the native plugins declare, offered or not.
pub const sign_in_providers = native_plugins.merged_sign_in_providers;
/// The providers the native plugins register into contracts.
pub const providers = native_plugins.merged_providers;
pub const plugin_routes = native_plugins.merged_routes;
pub const row_actions = native_plugins.merged_row_actions;
pub const pages = native_plugins.merged_pages;
pub const menu = native_plugins.merged_menu;
pub const icons = native_plugins.merged_icons;
pub const panels = native_plugins.merged_panels;
pub const registered_statuses = native_plugins.merged_registered_statuses;
pub const sign_in_at = native_plugins.merged_sign_in_at;
pub const admin_brand = native_plugins.merged_admin_brand;
pub const app_picker_segment = native_plugins.merged_app_picker_segment;
pub const variants = native_plugins.merged_variants;
pub const work_start = native_plugins.merged_work_start;
pub const hosted = native_plugins.merged_hosted;
pub const translations = native_plugins.merged_translations;
pub const stateful_plugins = native_plugins.merged_stateful;
pub const operator_commands = native_plugins.merged_operator_commands;
pub const before_command = native_plugins.merged_before_command;
pub const serving = native_plugins.merged_serving;

/// Once the schema is applied: the declared types and fields, then each plugin's own
/// `bootstrap`, as the system, in name order.
fn bootstrap(ctx: *sdk.Ctx) sdk.Error!void {
    @import("std").debug.assert(ctx.caller == .system);
    @import("std").debug.assert(ctx.db.transaction_depth == 0);
    try media.bootstrap(ctx);
    try ai.bootstrap(ctx);
    try design_operations.bootstrap(ctx);
    try queries_read(ctx);
    try plugin_types.apply_all(ctx);
    try apply_declared_roles(ctx);

    inline for (native_plugins.all) |Plugin| {
        if (comptime plugin_define.has(Plugin, "bootstrap")) {
            try plugin_define.get(Plugin, "bootstrap")(ctx);
        }
    }
}

/// Each built-in plugin's prepared GROQ texts parse, as an installed plugin's do when it is
/// installed: one that does not stops the boot, naming the plugin, the query and why.
fn queries_read(ctx: *sdk.Ctx) sdk.Error!void {
    @import("std").debug.assert(ctx.caller == .system);

    inline for (native_plugins.all) |Plugin| {
        const queries = comptime if (@hasDecl(Plugin, "docs"))
            @import("../sdk/plugin/prepared_queries.zig").of(Plugin.docs)
        else
            &.{};

        plugin_lifecycle.queries_read(ctx, Plugin.manifest.name, queries) catch |err| {
            if (ctx.failure) |failure| {
                std.log.err("{s}", .{failure.message});
            }

            return err;
        };
    }
}

/// Core's roles, then each built-in plugin's, as each owner declares them.
pub fn apply_declared_roles(ctx: *sdk.Ctx) sdk.Error!void {
    @import("std").debug.assert(ctx.caller == .system);
    @import("std").debug.assert(role_registry.core.len > 0);

    try sdk.stored_roles.apply(ctx, role_registry.owner_core, &role_registry.core);

    inline for (native_plugins.all) |Plugin| {
        const declared = comptime @import("../sdk/plugin.zig").roles_of(Plugin);

        try sdk.stored_roles.declare(ctx, Plugin.manifest.name, declared);
    }
}
