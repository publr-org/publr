//! The host's index of what the loaded plugins declare: every operation by name, every
//! granted hook by its stage and target, the statuses and field kinds they add, and the
//! remotes switched off because their plugin is not there or does not fit.
const std = @import("std");
const model = @import("../../model.zig");
const registry = @import("../registry.zig");
const lifecycle = @import("../../operations/plugin/lifecycle.zig");
const sandboxed_plugins = @import("../sandboxed_plugins.zig");
const Loaded = @import("loaded.zig").Loaded;

const Host = sandboxed_plugins.Host;
const Target = sandboxed_plugins.Target;
const Off = sandboxed_plugins.Off;
const sandboxed_plugins_max = sandboxed_plugins.sandboxed_plugins_max;

pub fn reindex(host: *Host) !void {
    std.debug.assert(host.loaded.items.len <= sandboxed_plugins_max);

    _ = host.index_arena.reset(.retain_capacity);
    host.hooks = .empty;
    host.operations = .empty;
    host.statuses = null;
    host.kinds = null;
    host.manifests = &.{};
    host.off = &.{};

    const arena = host.index_arena.allocator();
    var statuses: std.ArrayList(model.flow.Added) = .empty;
    const manifests = try arena.alloc(model.sandboxed_plugin.Manifest, host.loaded.items.len);
    const there = try providers_of(arena, host.loaded.items);

    for (host.loaded.items, 0..) |*loaded, plugin_index| {
        const manifest = &loaded.manifest;
        const index: u32 = @intCast(plugin_index);

        manifests[plugin_index] = manifest.*;

        for (manifest.operations, 0..) |operation, entry| {
            const target: Target = .{
                .sandboxed_plugin = index,
                .entry = @intCast(entry),
            };

            try host.operations.put(arena, operation.name, target);
        }

        for (manifest.hooks, 0..) |hook, position| {
            if (lifecycle.hook_refused(hook.stage, hook.target)) {
                std.log.warn("{s}: a {t} hook on {s} is never loaded", .{
                    loaded.name(),
                    hook.stage,
                    hook.target,
                });
                continue;
            }

            const key = try model.sandboxed_plugin.hook_key(arena, hook);

            const user = model.sandboxed_plugin.contract_user(manifest);

            if (!model.plugin_contracts.remote_on(user, there, hook.target)) {
                continue;
            }

            // A hook on its own operation or event is its own business: never asked for.
            const own = model.sandboxed_plugin.own_target(manifest.name, hook.target);

            if (own or loaded.holds(key)) {
                const entry: u32 = @intCast(manifest.operations.len + position);
                const target: Target = .{
                    .sandboxed_plugin = index,
                    .entry = entry,
                };

                try add_hook(&host.hooks, arena, key, target);
            }
        }

        for (manifest.statuses) |added| {
            if (loaded.holds(try model.sandboxed_plugin.status_key(arena, added))) {
                try statuses.append(arena, added);
            }
        }
    }

    if (statuses.items.len > 0) {
        const built_in = registry.registered_statuses;
        const both = [_][]const model.flow.Added{ built_in, statuses.items };

        host.statuses = try std.mem.concat(arena, model.flow.Added, &both);
    }

    host.manifests = manifests;
    host.off = try off_of(arena, manifests, there);

    const known = try registry.with_kinds(arena, registry.Kinds.all, manifests);

    host.kinds = if (known.len == registry.Kinds.all.len) null else known;
}

/// Every remote off, of the compiled-in plugins and the loaded ones, against what is there.
fn off_of(
    arena: std.mem.Allocator,
    manifests: []const model.sandboxed_plugin.Manifest,
    there: []const model.plugin_contracts.Provider,
) ![]const Off {
    std.debug.assert(manifests.len <= sandboxed_plugins_max);

    const fit = model.plugin_contracts;
    const natives = registry.native_users();
    var list: std.ArrayList(Off) = .empty;
    var found: [fit.findings_max]fit.Finding = undefined;

    for (0..natives.len + manifests.len) |index| {
        const user = if (index < natives.len)
            natives[index]
        else
            model.sandboxed_plugin.contract_user(&manifests[index - natives.len]);
        const count = fit.check(user, there, &found);

        for (found[0..count]) |finding| {
            try list.append(arena, .{
                .plugin = user.plugin,
                .name = finding.name,
            });
        }
    }

    return list.items;
}

/// The compiled-in plugins and the loaded ones, as providers of operations' shapes.
fn providers_of(
    arena: std.mem.Allocator,
    loaded: []const Loaded,
) ![]const model.plugin_contracts.Provider {
    std.debug.assert(loaded.len <= sandboxed_plugins_max);

    const natives = try registry.native_providers(arena);
    const list = try arena.alloc(model.plugin_contracts.Provider, natives.len + loaded.len);

    @memcpy(list[0..natives.len], natives);

    for (loaded, list[natives.len..]) |*one, *provider| {
        provider.* = try model.sandboxed_plugin.contract_provider(arena, &one.manifest);
    }

    return list;
}

fn add_hook(
    hooks: *std.StringHashMapUnmanaged([]const Target),
    arena: std.mem.Allocator,
    key: []const u8,
    target: Target,
) !void {
    std.debug.assert(key.len > 0);
    std.debug.assert(target.entry < 1024);

    const existing = hooks.get(key) orelse &[_]Target{};
    const extended = try arena.alloc(Target, existing.len + 1);

    @memcpy(extended[0..existing.len], existing);
    extended[existing.len] = target;
    try hooks.put(arena, key, extended);
}
