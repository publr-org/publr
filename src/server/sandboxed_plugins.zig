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
const loaded_module = @import("sandboxed_plugins/loaded.zig");
const Loaded = loaded_module.Loaded;
const interface = @import("sandboxed_plugins/interface.zig");
const translations_module = @import("sandboxed_plugins/translations.zig");
const components_module = @import("sandboxed_plugins/components.zig");
const interactive_module = @import("sandboxed_plugins/interactive.zig");
const counted_module = @import("sandboxed_plugins/counted.zig");
const said_memory = @import("sandboxed_plugins/said_memory.zig");
const loading = @import("sandboxed_plugins/loading.zig");
pub const transient_module = @import("sandboxed_plugins/transient.zig");
const Languages = @import("languages.zig").Languages;

pub const Files = files_module.Files;
pub const hash_len = files_module.hash_len;

/// WAMR's own pool: modules, instances' bookkeeping, stacks. Linear memories are mapped
/// apart, each held to its plugin's memory limit. In the browser the browser's WebAssembly
/// keeps its own, so the pool is only the least the API takes. The least it starts with: it
/// grows to what the plugins loaded take (`heap_for`).
pub const heap_bytes: u32 = if (wasm.in_browser) wasm.heap_bytes_min else 32 << 20;
/// What a loaded module takes of the pool for each byte of it: its code as the interpreter
/// rewrites it, its tables and data.
pub const heap_per_module_byte: u64 = 4;
/// What each loaded plugin's instance takes of the pool beside its module: its stack and
/// bookkeeping.
pub const heap_per_plugin: u64 = 2 << 20;

/// The pool every plugin of `module_bytes` in all, `plugins` of them, loaded at once, each
/// instantiated in one call chain, takes.
pub fn heap_for(module_bytes: u64, plugins: u64) u64 {
    std.debug.assert(plugins <= sandboxed_plugins_max * 2);
    std.debug.assert(module_bytes <= @as(u64, sandboxed_plugins_max) * 2 * (16 << 20));

    return @max(heap_bytes, heap_bytes + module_bytes * heap_per_module_byte +
        plugins * heap_per_plugin);
}
pub const sandboxed_plugins_max: u32 = model.sandboxed_plugin.sandboxed_plugins_max;

/// A loaded plugin's views' browser code (`publr.stores`), served to its frame.
pub const Stores = struct {
    plugin: []const u8,
    code: []const u8,
};

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
    /// Each loaded plugin's views' browser code, when it brings any, read beside its
    /// translations.
    stores: std.ArrayList(Stores) = .empty,
    /// Each loaded plugin's site components, read beside its translations.
    components: std.ArrayList(sdk.sandboxed_plugins.Component) = .empty,
    /// Each loaded plugin's interactive components, read beside its translations.
    interactive: std.ArrayList(sdk.sandboxed_plugins.Interactive) = .empty,
    /// The catalogues they join, told after every load; none in a process without them.
    languages: ?*Languages = null,
    /// The plugins this server was started with (`serve --plugin`), loaded after the
    /// installed ones; null without any.
    transient: ?*transient_module.Transient = null,
    /// Requests open now (`request_begin`): while any is, a plugin's instance serves every
    /// call into it; the last one's end drops every instance.
    requests: u32 = 0,
    /// The open request's own figures, and whether its lines are said (`counted.zig`).
    counted: counted_module.Request = .{},

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
        host.transient = null;
        host.requests = 0;
        host.counted = .{};
        host.statuses = null;
        host.kinds = null;
        host.manifests = &.{};
        host.interface = .{
            .context = host,
            .vtable = &interface.vtable,
        };
    }

    pub fn deinit(host: *Host) void {
        std.debug.assert(host.heap.len >= heap_bytes);
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
    /// logged and left out; the others run (`loading.zig`).
    pub fn load_all(host: *Host, connection: *@import("../lib/db.zig").Db) !void {
        std.debug.assert(connection.transaction_depth == 0);
        std.debug.assert(host.loaded.items.len <= sandboxed_plugins_max);

        return loading.load_all(host, connection);
    }

    /// What the request open now cost in every plugin, the instances still held included.
    pub fn counted_total(host: *const Host) counted_module.Plugin {
        std.debug.assert(host.loaded.items.len <= sandboxed_plugins_max);

        return counted_module.total_of(host.loaded.items);
    }

    /// A request begins: an HTTP request, or a top-level call outside one. Until it ends,
    /// each plugin is instantiated at most once and that instance serves every call into it.
    pub fn request_begin(host: *Host) void {
        std.debug.assert(host.requests < loaded_module.requests_open_max);
        std.debug.assert(host.loaded.items.len <= sandboxed_plugins_max);

        // With none open, none was left: a request never begins on another's instances.
        if (host.requests == 0) {
            host.drop_idle();
            host.counted.begin();

            for (host.loaded.items) |*loaded| {
                loaded.counted = .{};
                loaded.largest = .{};
            }
        }

        host.requests += 1;
    }

    /// Every instance no call is running on, dropped: what begins next begins on fresh ones.
    /// A queued run begins and ends with this, whatever request it runs inside: one run
    /// never works on what another left in a plugin's memory.
    pub fn drop_idle(host: *Host) void {
        std.debug.assert(host.loaded.items.len <= sandboxed_plugins_max);
        std.debug.assert(host.requests <= loaded_module.requests_open_max);

        for (host.loaded.items) |*loaded| {
            // A call still running on one keeps it until that call's own end.
            if (loaded.running == 0) {
                loaded.drop_instance();
            }
        }
    }

    /// A request ends. The last one open takes every instance with it: nothing a plugin
    /// kept in its memory is there for the next request, whoever makes it.
    pub fn request_end(host: *Host) void {
        std.debug.assert(host.requests > 0);
        std.debug.assert(host.loaded.items.len <= sandboxed_plugins_max);

        host.requests -= 1;

        if (host.requests == 0) {
            host.drop_idle();
            said_memory.half_full(host.loaded.items, &host.counted);

            if (host.counted.on) {
                counted_module.say(&host.counted, host.loaded.items);
            }
        }
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

test {
    _ = @import("sandboxed_plugins/scenarios.zig");
    _ = @import("sandboxed_plugins/scenarios_remotes.zig");
    _ = @import("sandboxed_plugins/scenarios_hook_runs.zig");
    _ = @import("sandboxed_plugins/scenarios_user_types.zig");
    _ = @import("sandboxed_plugins/scenarios_staff.zig");
    _ = @import("sandboxed_plugins/scenarios_internal_rules.zig");
    _ = @import("sandboxed_plugins/scenarios_laid_out.zig");
    _ = @import("sandboxed_plugins/scenarios_hostile.zig");
    _ = @import("sandboxed_plugins/scenarios_errors.zig");
    _ = @import("sandboxed_plugins/scenarios_reads.zig");
    _ = @import("sandboxed_plugins/scenarios_domains.zig");
    _ = @import("sandboxed_plugins/scenarios_queued.zig");
    _ = @import("sandboxed_plugins/scenarios_taxonomies.zig");
    _ = @import("sandboxed_plugins/scenarios_enable_many.zig");
    _ = @import("sandboxed_plugins/scenarios_soak.zig");
    _ = @import("sandboxed_plugins/scenarios_placed_fields.zig");
    _ = @import("sandboxed_plugins/scenarios_made_files.zig");
    _ = @import("sandboxed_plugins/scenarios_test_clock.zig");
    _ = @import("sandboxed_plugins/scenarios_ledger.zig");
    _ = @import("sandboxed_plugins/scenarios_instances.zig");
    _ = @import("sandboxed_plugins/scenarios_counted.zig");
    _ = files_module;
    _ = interface;
    _ = translations_module;
    _ = components_module;
    _ = counted_module;
    _ = loading;
    _ = @import("sandboxed_plugins/indexing.zig");
}
