//! The `sdk.plugins.Plugins` the host hands every context: finding a plugin's operation,
//! running it, running the hooks plugins hold, and reading a module to install.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const files_module = @import("files.zig");
const invoke_module = @import("invoke.zig");
const Loaded = @import("loaded.zig").Loaded;
const contracts = @import("../../sdk/contract.zig");
const sandboxed_plugins = @import("../sandboxed_plugins.zig");
const modifying = @import("modifying.zig");
const hooks_many = @import("hooks_many.zig");
const hooks = @import("hooks.zig");
const queued = @import("queued.zig");
const installing = @import("installing.zig");
const Host = sandboxed_plugins.Host;
const Target = sandboxed_plugins.Target;
const hash_len = files_module.hash_len;
const sandboxed_plugins_max = sandboxed_plugins.sandboxed_plugins_max;

pub const vtable: sdk.sandboxed_plugins.SandboxedPlugins.VTable = .{
    .receive = &installing.receive,
    .consume = &installing.consume,
    .stage = &installing.stage,
    .statuses = &statuses_of,
    .kinds = &kinds_of,
    .stores = &stores_of,
    .components = &components_of,
    .interactive = &interactive_of,
    .remote_off = &remote_off,
    .holds = &holds,
    .find = &find,
    .manifests = &manifests,
    .run = &run,
    .json_of = &json_of,
    .text_field = &text_field,
    .hooked = &hooks.hooked,
    .before = &hooks.before,
    .after = &hooks.after,
    .event = &hooks.event,
    .on_hooks = &queued.on_hooks,
    .on = &queued.on,
    .on_input = &queued.on_input,
    .modify = &modifying.modify,
    .compute = &modifying.compute,
    .call_as = &call_as,
    .job = &queued.job,
    .extra = &extra,
    .before_many = &hooks_many.before,
    .after_many = &hooks_many.after,
    .request_begin = &request_begin,
    .request_end = &request_end,
    .counted = &counted,
};

fn counted(context: *anyopaque, told: sdk.sandboxed_plugins.Counted) void {
    const host = host_of(context);

    std.debug.assert(host.loaded.items.len <= sandboxed_plugins_max);

    if (host.requests > 0) {
        host.counted.tell(told);
    }
}

fn request_begin(context: *anyopaque) void {
    const host = host_of(context);

    std.debug.assert(host.loaded.items.len <= sandboxed_plugins_max);

    host.request_begin();
}

fn request_end(context: *anyopaque) void {
    const host = host_of(context);

    std.debug.assert(host.requests > 0);

    host.request_end();
}

pub fn host_of(context: *anyopaque) *Host {
    return @ptrCast(@alignCast(context));
}

fn statuses_of(context: *anyopaque) ?[]const model.flow.Added {
    const host = host_of(context);

    std.debug.assert(host.loaded.items.len <= sandboxed_plugins_max);

    return host.statuses;
}

fn kinds_of(context: *anyopaque) ?[]const model.kinds.Kind {
    const host = host_of(context);

    std.debug.assert(host.loaded.items.len <= sandboxed_plugins_max);

    return host.kinds;
}

fn stores_of(context: *anyopaque, plugin: []const u8) ?[]const u8 {
    const host = host_of(context);

    std.debug.assert(host.loaded.items.len <= sandboxed_plugins_max);

    for (host.stores.items) |one| {
        if (std.mem.eql(u8, one.plugin, plugin)) {
            return one.code;
        }
    }

    return null;
}

fn components_of(context: *anyopaque) []const sdk.sandboxed_plugins.Component {
    const host = host_of(context);

    std.debug.assert(host.loaded.items.len <= sandboxed_plugins_max);
    std.debug.assert(host.components.items.len <= components_max);

    return host.components.items;
}

const components_max = sandboxed_plugins_max * 64;

fn interactive_of(context: *anyopaque) []const sdk.sandboxed_plugins.Interactive {
    const host = host_of(context);

    std.debug.assert(host.loaded.items.len <= sandboxed_plugins_max);
    std.debug.assert(host.interactive.items.len <= host.loaded.items.len);

    return host.interactive.items;
}

fn holds(context: *anyopaque, plugin: []const u8, key: []const u8) bool {
    const host = host_of(context);

    std.debug.assert(key.len > 0);

    const loaded = host.find_loaded(plugin) orelse return false;

    return loaded.holds(key);
}

fn remote_off(context: *anyopaque, plugin: []const u8, name: []const u8) bool {
    const host = host_of(context);

    std.debug.assert(host.loaded.items.len <= sandboxed_plugins_max);

    return host.remote_off(plugin, name);
}

fn manifests(context: *anyopaque) []const sdk.sandboxed_plugins.Manifest {
    const host = host_of(context);

    std.debug.assert(host.manifests.len <= host.loaded.items.len);

    return host.manifests;
}

fn find(context: *anyopaque, name: []const u8) ?sdk.sandboxed_plugins.Operation {
    const host = host_of(context);
    const target = host.operations.get(name) orelse return null;
    const loaded = &host.loaded.items[target.sandboxed_plugin];
    const declared = loaded.manifest.operations[target.entry];

    std.debug.assert(std.mem.eql(u8, declared.name, name));

    return .{
        .name = declared.name,
        .kind = if (declared.kind == .read) .read else .write,
        .description = declared.description,
        .open = declared.open,
        .untrusted_callers = declared.untrusted_callers,
        .limit = declared.limit,
        .destructive = declared.destructive,
        .answer = declared.answer,
        .fields = declared.fields,
        .help = declared.help,
        .input = declared.input,
        .secret = declared.secret,
        .deprecated = declared.deprecated,
        .sandboxed_plugin = target.sandboxed_plugin,
        .entry = target.entry,
    };
}

fn run(
    context: *anyopaque,
    ctx: *sdk.Ctx,
    found: sdk.sandboxed_plugins.Operation,
    input: Passed,
) sdk.Error!Passed {
    const host = host_of(context);
    const loaded = &host.loaded.items[found.sandboxed_plugin];

    std.debug.assert(found.name.len > 0);

    var access = try access_of(loaded, ctx);

    return invoke_module.invoke_passed(loaded, ctx, &access, found.entry, .{
        .in = input,
    });
}

const Passed = sdk.sandboxed_plugins.Passed;

fn json_of(
    context: *anyopaque,
    arena: std.mem.Allocator,
    piece: []const u8,
    form: sdk.sandboxed_plugins.Form,
) sdk.Error![]const u8 {
    std.debug.assert(host_of(context).loaded.items.len <= sandboxed_plugins_max);

    return invoke_module.json_of(arena, .{
        .laid = piece,
    }, form);
}

fn text_field(
    context: *anyopaque,
    arena: std.mem.Allocator,
    piece: []const u8,
    name: []const u8,
) ?[]const u8 {
    std.debug.assert(host_of(context).loaded.items.len <= sandboxed_plugins_max);

    return @import("held.zig").text_field(arena, piece, name);
}

fn call_as(
    context: *anyopaque,
    ctx: *sdk.Ctx,
    plugin: []const u8,
    name: []const u8,
    input: []const u8,
) sdk.Error![]const u8 {
    const host = host_of(context);
    const loaded = host.find_loaded(plugin) orelse return error.NotFound;

    std.debug.assert(name.len > 0);
    std.debug.assert(ctx.caller != .plugin);

    var access = try access_of(loaded, ctx);
    const saved = ctx.caller;

    ctx.caller = .{
        .plugin = .{
            .name = loaded.name(),
            .on_behalf_of = saved.user_id(),
            .access = &access,
            .roles = saved.roles(),
        },
    };
    defer ctx.caller = saved;

    return @import("../registry.zig").SDK.call_json(ctx, name, input);
}

/// Runs `part` of installed plugin `name`'s plugin (`sampler.has_motto`): its entries
/// follow the jobs', each rule's `values` then `matches`, then each kind's `validate`,
/// `text` and `editor`, then each dimension's `options`.
fn extra(
    context: *anyopaque,
    ctx: *sdk.Ctx,
    part: sdk.sandboxed_plugins.Part,
    name: []const u8,
    input: []const u8,
) sdk.Error![]const u8 {
    const host = host_of(context);
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse return error.NotFound;
    const loaded = host.find_loaded(name[0..dot]) orelse return error.NotFound;
    const manifest = loaded.manifest;
    const own = name[dot + 1 ..];
    const first = manifest.operations.len + manifest.hooks.len + manifest.jobs.len;

    std.debug.assert(input.len > 0);

    const rule = part == .rule_values or part == .rule_matches;
    const second = part == .rule_matches or part == .kind_text;
    const kind_part: u32 = switch (part) {
        .kind_validate => 0,
        .kind_text => 1,
        .kind_editor => 2,
        .rule_values, .rule_matches, .dimension_options => 0,
    };
    const kinds_first = first + manifest.location_rules.len * 2;

    for (manifest.location_rules, 0..) |declared, index| {
        if (rule and std.mem.eql(u8, declared.name, own)) {
            const entry = first + index * 2 + @intFromBool(second);

            return run_entry(loaded, ctx, @intCast(entry), input);
        }
    }

    for (manifest.field_kinds, 0..) |declared, index| {
        if (!rule and part != .dimension_options and std.mem.eql(u8, declared.name, own)) {
            const entry = kinds_first + index * 3 + kind_part;

            return run_entry(loaded, ctx, @intCast(entry), input);
        }
    }

    const dimensions_first = kinds_first + manifest.field_kinds.len * 3;

    for (manifest.dimensions, 0..) |declared, index| {
        if (part == .dimension_options and std.mem.eql(u8, declared.name, own)) {
            return run_entry(loaded, ctx, @intCast(dimensions_first + index), input);
        }
    }

    return error.NotFound;
}

fn run_entry(loaded: *Loaded, ctx: *sdk.Ctx, entry: u32, input: []const u8) sdk.Error![]const u8 {
    std.debug.assert(entry < 1 << 16);
    std.debug.assert(input.len > 0);

    var access = try access_of(loaded, ctx);

    return invoke_module.invoke(loaded, ctx, &access, entry, input);
}

/// What the plugin may reach this call: its grants with their flags, and its own types.
pub fn access_of(loaded: *Loaded, ctx: *sdk.Ctx) sdk.Error!sdk.plugin_access.Access {
    std.debug.assert(loaded.name().len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    return .{
        .held = loaded.held,
        .depends_on = loaded.manifest.depends_on,
        .compatible_with = loaded.manifest.compatible_with,
        .own_types = loaded.own_types,
        .secrets = loaded.manifest.secrets,
        .remotes = loaded.manifest.remotes,
        .provided = try provided_to(ctx, loaded.manifest.contracts),
        .contracts = try names_of(ctx, loaded.manifest.contracts),
    };
}

fn names_of(
    ctx: *sdk.Ctx,
    owned: []const model.published.Contract,
) sdk.Error![]const []const u8 {
    const names = try ctx.arena.alloc([]const u8, owned.len);

    for (owned, names) |contract, *name| {
        name.* = contract.name;
    }

    return names;
}

/// The operations providers, compiled in or installed, registered for the contracts `owned`.
fn provided_to(
    ctx: *sdk.Ctx,
    owned: []const model.published.Contract,
) sdk.Error![]const []const u8 {
    if (owned.len == 0) {
        return &.{};
    }

    var operations: std.ArrayList([]const u8) = .empty;

    for (owned) |contract| {
        for (try contracts.listed(ctx, contract.name)) |one| {
            for (one.provider.parts) |part| {
                try operations.append(ctx.arena, part.operation);
            }
        }
    }

    return operations.items;
}

test {
    _ = modifying;
    _ = @import("projected.zig");
}
