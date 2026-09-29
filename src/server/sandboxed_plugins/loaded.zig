//! One installed plugin as the host holds it: its module, its manifest, what it is granted,
//! and, once something calls it, its instance. The instance is disposable: a trap or an
//! exhausted budget drops it and the next call makes a fresh one.
const std = @import("std");
const wasm = @import("publr_wasm");
const model = @import("../../model.zig");
const sdk = @import("../../sdk.zig");
const json = @import("../../lib/json.zig");
const store = @import("../../store.zig");

const sandboxed_plugin = model.sandboxed_plugin;
const wire = @import("../../sdk/plugin/wire.zig");

/// Instructions the fast interpreter runs in a millisecond: about 490,000 on an M-series core
/// in a release build (a tight loop), rounded down. What turns a CPU limit into the budget
/// WAMR enforces; a debug build runs about eight times slower against the same budget.
pub const instructions_per_ms: u32 = 400_000;
pub const stack_bytes: u32 = 64 << 10;

pub const Loaded = struct {
    arena_state: std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    bytes: []u8,
    manifest: sandboxed_plugin.Manifest,
    module: wasm.Module,
    instance: ?wasm.Instance = null,
    result_offset: u32 = 0,
    granted: []const []const u8,
    own_types: []const []const u8,
    content_access: ContentAccess,
    limits: sandboxed_plugin.Effective,

    pub const ContentAccess = struct {
        scope: sandboxed_plugin.ContentAccess.Scope = .public,
        types: []const []const u8 = &.{},
    };

    /// Loads a stored row and its module. `bytes` become the plugin's; on error, freed.
    pub fn init(
        loaded: *Loaded,
        gpa: std.mem.Allocator,
        runtime: *wasm.Runtime,
        row: store.sandboxed_plugins.Row,
        bytes: []u8,
    ) !void {
        std.debug.assert(row.name.len > 0);
        std.debug.assert(bytes.len > 0);

        loaded.* = .{
            .arena_state = std.heap.ArenaAllocator.init(gpa),
            .gpa = gpa,
            .bytes = bytes,
            .manifest = undefined,
            .module = undefined,
            .granted = &.{},
            .own_types = &.{},
            .content_access = .{},
            .limits = sandboxed_plugin.limits_default,
        };
        errdefer loaded.arena_state.deinit();
        errdefer gpa.free(bytes);

        const arena = loaded.arena_state.allocator();
        const options: std.json.ParseOptions = .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        };

        const manifest_text = try arena.dupe(u8, row.manifest);
        const granted_text = try arena.dupe(u8, row.granted);
        const access_text = try arena.dupe(u8, row.content_access);

        loaded.manifest = try json.parse(sandboxed_plugin.Manifest, arena, manifest_text, options);
        loaded.granted = try json.parse([]const []const u8, arena, granted_text, options);
        loaded.content_access = try json.parse(ContentAccess, arena, access_text, options);
        loaded.limits = sandboxed_plugin.effective_limits(loaded.manifest.limits, loaded.granted);
        loaded.own_types = try own_types_of(arena, &loaded.manifest);

        var problem: wasm.Problem = .{};

        loaded.module = wasm.Module.load(runtime, bytes, &problem) catch |err| {
            std.log.err("plugin {s}: {s}", .{ row.name, problem.text() });
            return err;
        };
    }

    pub fn deinit(loaded: *Loaded) void {
        std.debug.assert(loaded.bytes.len > 0);
        std.debug.assert(loaded.manifest.name.len > 0);

        loaded.drop_instance();
        loaded.module.unload();
        loaded.gpa.free(loaded.bytes);
        loaded.arena_state.deinit();
    }

    pub fn name(loaded: *const Loaded) []const u8 {
        std.debug.assert(loaded.manifest.name.len > 0);
        std.debug.assert(loaded.manifest.name.len <= sandboxed_plugin.name_len_max);

        return loaded.manifest.name;
    }

    pub fn holds(loaded: *const Loaded, key: []const u8) bool {
        std.debug.assert(key.len > 0);
        std.debug.assert(loaded.granted.len <= sandboxed_plugin.requests_max);

        return model.permission.contains(loaded.granted, key);
    }

    /// The instance, made on first use and again after one was dropped.
    pub fn ensure_instance(loaded: *Loaded) !*wasm.Instance {
        std.debug.assert(loaded.limits.memory_mib > 0);
        std.debug.assert(loaded.bytes.len > 0);

        if (loaded.instance) |*instance| {
            return instance;
        }

        var problem: wasm.Problem = .{};
        var instance = wasm.Instance.init(&loaded.module, .{
            .memory_pages_max = loaded.limits.memory_mib * 16,
            .stack_bytes = stack_bytes,
        }, &problem) catch |err| {
            std.log.err("plugin {s}: {s}", .{ loaded.name(), problem.text() });
            return err;
        };
        errdefer instance.deinit();

        const offset = try instance.call("publr_alloc", &.{wire.result_bytes}, .{
            .instructions_max = 100_000,
        }, &problem);

        if (offset == 0) {
            return error.OutOfMemory;
        }

        loaded.instance = instance;
        loaded.result_offset = offset;

        return &loaded.instance.?;
    }

    pub fn drop_instance(loaded: *Loaded) void {
        std.debug.assert(loaded.bytes.len > 0);

        if (loaded.instance) |*instance| {
            instance.deinit();
        }

        loaded.instance = null;
        loaded.result_offset = 0;

        std.debug.assert(loaded.instance == null);
    }

    /// The budget one call gets.
    pub fn instructions_max(loaded: *const Loaded) u31 {
        std.debug.assert(loaded.limits.cpu_ms > 0);
        std.debug.assert(instructions_per_ms > 0);

        const budget = @as(u64, loaded.limits.cpu_ms) * instructions_per_ms;

        return @intCast(@min(budget, std.math.maxInt(u31)));
    }
};

fn own_types_of(
    arena: std.mem.Allocator,
    manifest: *const sandboxed_plugin.Manifest,
) ![]const []const u8 {
    std.debug.assert(manifest.name.len > 0);
    std.debug.assert(manifest.content_types.len <= 64);

    const handles = try arena.alloc([]const u8, manifest.content_types.len);

    for (manifest.content_types, handles) |def, *handle| {
        handle.* = def.handle;
    }

    return handles;
}
