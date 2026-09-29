//! The installed plugins of a project, as the server holds them: the sandbox's runtime, every
//! installed plugin loaded from its row and its file, and the `sdk.plugins.Plugins` every
//! context carries, through which the SDK reaches their operations and hooks.
const std = @import("std");
const wasm = @import("publr_wasm");
const sdk = @import("../sdk.zig");
const model = @import("../model.zig");
const store = @import("../store.zig");
const registry = @import("registry.zig");
const files_module = @import("sandboxed_plugins/files.zig");
const invoke_module = @import("sandboxed_plugins/invoke.zig");
const Loaded = @import("sandboxed_plugins/loaded.zig").Loaded;
const interface = @import("sandboxed_plugins/interface.zig");

pub const Files = files_module.Files;
pub const hash_len = files_module.hash_len;

/// WAMR's own pool: modules, instances' bookkeeping, stacks. Linear memories are mapped
/// apart, each held to its plugin's memory limit.
pub const heap_bytes: u32 = 32 << 20;
pub const sandboxed_plugins_max: u32 = model.sandboxed_plugin.sandboxed_plugins_max;

pub const Target = struct { sandboxed_plugin: u32, entry: u32 };

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
    /// The build's roles with every plugin's merged in, while any plugin declares one.
    roles: ?[]const model.role.Role = null,
    /// Every loaded plugin's manifest, in load order: what help lists.
    manifests: []const model.sandboxed_plugin.Manifest = &.{},
    interface: sdk.sandboxed_plugins.SandboxedPlugins,

    pub fn init(host: *Host, gpa: std.mem.Allocator, io: std.Io, dir: []const u8) !void {
        std.debug.assert(dir.len > 0);
        std.debug.assert(heap_bytes >= wasm.heap_bytes_min);

        host.gpa = gpa;
        host.heap = try gpa.alloc(u8, heap_bytes);
        errdefer gpa.free(host.heap);

        try host.runtime.init(.{ .heap = host.heap, .imports = &invoke_module.imports });
        errdefer host.runtime.deinit();

        host.files = try Files.open(io, dir);
        host.loaded = try .initCapacity(gpa, 16);
        host.hooks = .empty;
        host.operations = .empty;
        host.index_arena = std.heap.ArenaAllocator.init(gpa);
        host.roles = null;
        host.interface = .{ .context = host, .vtable = &interface.vtable };
    }

    pub fn deinit(host: *Host) void {
        std.debug.assert(host.heap.len == heap_bytes);
        std.debug.assert(host.loaded.items.len <= sandboxed_plugins_max);

        for (host.loaded.items) |*loaded| {
            loaded.deinit();
        }

        host.loaded.deinit(host.gpa);
        host.index_arena.deinit();
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

        host.files.sweep(keep.items);
        try host.reindex();
    }

    fn load_one(host: *Host, row: store.sandboxed_plugins.Row) !void {
        std.debug.assert(row.name.len > 0);
        std.debug.assert(files_module.valid_hash(row.hash));

        const bytes = try host.files.read(host.gpa, row.hash);
        const slot = try host.loaded.addOne(host.gpa);
        errdefer _ = host.loaded.pop();

        try slot.init(host.gpa, &host.runtime, row, bytes);
    }

    fn reindex(host: *Host) !void {
        std.debug.assert(host.loaded.items.len <= sandboxed_plugins_max);

        _ = host.index_arena.reset(.retain_capacity);
        host.hooks = .empty;
        host.operations = .empty;
        host.roles = null;
        host.manifests = &.{};

        const arena = host.index_arena.allocator();
        var roles: std.ArrayList(model.role.Role) = .empty;
        const manifests = try arena.alloc(model.sandboxed_plugin.Manifest, host.loaded.items.len);

        for (host.loaded.items, 0..) |*loaded, plugin_index| {
            const manifest = &loaded.manifest;
            const index: u32 = @intCast(plugin_index);

            manifests[plugin_index] = manifest.*;

            for (manifest.operations, 0..) |operation, entry| {
                const target: Target = .{ .sandboxed_plugin = index, .entry = @intCast(entry) };

                try host.operations.put(arena, operation.name, target);
            }

            for (manifest.hooks, 0..) |hook, position| {
                const key = try model.sandboxed_plugin.hook_key(arena, hook);

                if (loaded.holds(key)) {
                    const entry: u32 = @intCast(manifest.operations.len + position);
                    const target: Target = .{ .sandboxed_plugin = index, .entry = entry };

                    try add_hook(&host.hooks, arena, key, target);
                }
            }

            try roles.appendSlice(arena, manifest.roles);
        }

        if (roles.items.len > 0) {
            host.roles = try merge_roles(arena, registry.SDK.roles, roles.items);
        }

        host.manifests = manifests;
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

/// The build's roles with the plugins' merged in by name, as the build merges plugins'.
fn merge_roles(
    arena: std.mem.Allocator,
    base: []const model.role.Role,
    added: []const model.role.Role,
) ![]const model.role.Role {
    std.debug.assert(base.len > 0);
    std.debug.assert(added.len > 0);

    var roles: std.ArrayList(model.role.Role) = .empty;

    try roles.appendSlice(arena, base);

    for (added) |role| {
        const found = for (roles.items) |*existing| {
            if (std.mem.eql(u8, existing.name, role.name)) {
                break existing;
            }
        } else null;

        if (found) |existing| {
            const both = [_][]const []const u8{ existing.grants, role.grants };

            existing.grants = try std.mem.concat(arena, []const u8, &both);
        } else if (roles.items.len < model.role.roles_max) {
            try roles.append(arena, role);
        }
    }

    return roles.items;
}

test {
    _ = @import("sandboxed_plugins/scenarios.zig");
    _ = files_module;
    _ = interface;
}
