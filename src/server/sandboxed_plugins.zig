//! The installed plugins of a project, as the server holds them: the sandbox's runtime, every
//! installed plugin loaded from its row and its file, and the `sdk.plugins.Plugins` every
//! context carries, through which the SDK reaches their operations and hooks.
const std = @import("std");
const wasm = @import("publr_wasm");
const sdk = @import("../sdk.zig");
const model = @import("../model.zig");
const store = @import("../store.zig");
const registry = @import("registry.zig");
const lifecycle = @import("../operations/plugin/lifecycle.zig");
const files_module = @import("sandboxed_plugins/files.zig");
const invoke_module = @import("sandboxed_plugins/invoke.zig");
const Loaded = @import("sandboxed_plugins/loaded.zig").Loaded;
const interface = @import("sandboxed_plugins/interface.zig");
const translations_module = @import("sandboxed_plugins/translations.zig");
const Languages = @import("languages.zig").Languages;

pub const Files = files_module.Files;
pub const hash_len = files_module.hash_len;

/// WAMR's own pool: modules, instances' bookkeeping, stacks. Linear memories are mapped
/// apart, each held to its plugin's memory limit. In the browser the browser's WebAssembly
/// keeps its own, so the pool is only the least the API takes.
pub const heap_bytes: u32 = if (wasm.in_browser) wasm.heap_bytes_min else 32 << 20;
pub const sandboxed_plugins_max: u32 = model.sandboxed_plugin.sandboxed_plugins_max;

pub const Target = struct {
    sandboxed_plugin: u32,
    entry: u32,
};

/// A remote switched off for the plugin that uses it.
pub const Off = struct {
    plugin: []const u8,
    name: []const u8,
};

pub const Host = struct {
    gpa: std.mem.Allocator,
    heap: []u8,
    runtime: wasm.Runtime,
    files: Files,
    loaded: std.ArrayList(Loaded),
    /// `stage:target` of every granted hook, and the name of every operation, to its entry.
    hooks: std.StringHashMapUnmanaged([]const Target),
    operations: std.StringHashMapUnmanaged(Target),
    index_arena: std.heap.ArenaAllocator,
    /// The build's added statuses with every granted one plugins add, while any is granted.
    statuses: ?[]const model.flow.Added = null,
    /// The build's field kinds with the loaded plugins', while any brings one.
    kinds: ?[]const model.kinds.Kind = null,
    /// Every loaded plugin's manifest, in load order: what help lists.
    manifests: []const model.sandboxed_plugin.Manifest = &.{},
    /// Every remote switched off, compiled-in plugins' and loaded ones': its plugin is not
    /// there, or it does not fit. Calls to it answer `Unavailable`, its hooks don't run.
    off: []const Off = &.{},
    interface: sdk.sandboxed_plugins.SandboxedPlugins,
    /// The loaded plugins' translations, read from their modules on each load.
    translations_arena: std.heap.ArenaAllocator,
    translations: std.ArrayList(@import("../sdk/plugin.zig").OwnedTranslation) = .empty,
    /// The catalogues they join, told after every load; none in a process without them.
    languages: ?*Languages = null,

    pub fn init(host: *Host, gpa: std.mem.Allocator, io: std.Io, dir: []const u8) !void {
        std.debug.assert(dir.len > 0);
        std.debug.assert(heap_bytes >= wasm.heap_bytes_min);

        host.gpa = gpa;
        host.heap = try gpa.alloc(u8, heap_bytes);
        errdefer gpa.free(host.heap);

        try host.runtime.init(host.heap, &invoke_module.imports, .{});
        errdefer host.runtime.deinit();

        host.files = try Files.open(io, dir);
        host.loaded = try .initCapacity(gpa, 16);
        host.hooks = .empty;
        host.operations = .empty;
        host.index_arena = std.heap.ArenaAllocator.init(gpa);
        host.translations_arena = std.heap.ArenaAllocator.init(gpa);
        host.translations = .empty;
        host.languages = null;
        host.statuses = null;
        host.kinds = null;
        host.manifests = &.{};
        host.interface = .{
            .context = host,
            .vtable = &interface.vtable,
        };
    }

    pub fn deinit(host: *Host) void {
        std.debug.assert(host.heap.len == heap_bytes);
        std.debug.assert(host.loaded.items.len <= sandboxed_plugins_max);

        for (host.loaded.items) |*loaded| {
            loaded.deinit();
        }

        host.loaded.deinit(host.gpa);
        host.index_arena.deinit();
        host.translations_arena.deinit();
        host.files.close();
        host.runtime.deinit();
        host.gpa.free(host.heap);
    }

    pub fn sandboxed_plugins(host: *Host) *const sdk.sandboxed_plugins.SandboxedPlugins {
        std.debug.assert(host.interface.context == @as(*anyopaque, host));
        return &host.interface;
    }

    /// Unloads everything and loads every enabled plugin again from its row and file:
    /// at start, and after any change to the plugins. A plugin that no longer loads is
    /// logged and left out; the others run.
    pub fn load_all(host: *Host, connection: *@import("../lib/db.zig").Db) !void {
        std.debug.assert(connection.transaction_depth == 0);
        std.debug.assert(host.loaded.items.len <= sandboxed_plugins_max);

        for (host.loaded.items) |*loaded| {
            loaded.deinit();
        }

        host.loaded.clearRetainingCapacity();
        _ = host.translations_arena.reset(.retain_capacity);
        host.translations = .empty;

        var arena_state = std.heap.ArenaAllocator.init(host.gpa);
        defer arena_state.deinit();

        const rows = try store.sandboxed_plugins.list(connection, arena_state.allocator());

        var keep: std.ArrayList([]const u8) = .empty;

        for (rows) |row| {
            const kept = [_]?[]const u8{ row.hash, row.next_hash, row.previous_hash };

            for (kept) |hash_or_null| {
                if (hash_or_null) |hash| {
                    try keep.append(arena_state.allocator(), hash);
                }
            }

            if (!row.enabled) {
                continue;
            }

            host.load_one(row) catch |err| {
                std.log.err("plugin {s} did not load: {t}", .{ row.name, err });
            };
        }

        // A plugin in the trash keeps its modules until it goes for good.
        const in_trash = try store.trash.plugin_modules(
            connection,
            arena_state.allocator(),
            sandboxed_plugins_max * 3,
        );

        try keep.appendSlice(arena_state.allocator(), in_trash);
        host.files.sweep(keep.items);
        try host.reindex();

        if (host.languages) |languages| {
            try languages.set_installed(host.translations.items);
        }
    }

    fn load_one(host: *Host, row: store.sandboxed_plugins.Row) !void {
        std.debug.assert(row.name.len > 0);
        std.debug.assert(files_module.valid_hash(row.hash));

        const bytes = try host.files.read(host.gpa, row.hash);
        // Read before loading: the runtime rewrites the bytes it loads.
        const arena = host.translations_arena.allocator();
        const brought = try translations_module.of(arena, row.name, bytes);

        try host.translations.appendSlice(arena, brought);

        const slot = try host.loaded.addOne(host.gpa);
        errdefer _ = host.loaded.pop();

        try slot.init(host.gpa, &host.runtime, row, bytes);
    }

    fn reindex(host: *Host) !void {
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

                if (loaded.holds(key)) {
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

    /// Whether `plugin`'s remote `name` is off.
    pub fn remote_off(host: *const Host, plugin: []const u8, name: []const u8) bool {
        std.debug.assert(plugin.len > 0);
        std.debug.assert(name.len > 0);

        for (host.off) |off| {
            if (std.mem.eql(u8, off.plugin, plugin) and std.mem.eql(u8, off.name, name)) {
                return true;
            }
        }

        return false;
    }

    /// The loaded plugin called `name`.
    pub fn find_loaded(host: *Host, name: []const u8) ?*Loaded {
        std.debug.assert(name.len > 0);
        std.debug.assert(host.loaded.items.len <= sandboxed_plugins_max);

        for (host.loaded.items) |*loaded| {
            if (std.mem.eql(u8, loaded.name(), name)) {
                return loaded;
            }
        }

        return null;
    }
};

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

test {
    _ = @import("sandboxed_plugins/scenarios.zig");
    _ = @import("sandboxed_plugins/scenarios_remotes.zig");
    _ = @import("sandboxed_plugins/scenarios_hook_runs.zig");
    _ = @import("sandboxed_plugins/scenarios_errors.zig");
    _ = @import("sandboxed_plugins/scenarios_reads.zig");
    _ = @import("sandboxed_plugins/scenarios_domains.zig");
    _ = @import("sandboxed_plugins/scenarios_queued.zig");
    _ = files_module;
    _ = interface;
    _ = translations_module;
}
