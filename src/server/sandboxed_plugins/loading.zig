//! Loading the installed plugins into the host: every enabled one from its row and its
//! file, then the ones the server was started with, the pool made large enough for all of
//! them first, and what each brings beside its module (translations, browser code,
//! components) read on the way.
const std = @import("std");
const wasm = @import("publr_wasm");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const sandboxed_plugins = @import("../sandboxed_plugins.zig");
const files_module = @import("files.zig");
const invoke_module = @import("invoke.zig");
const indexing = @import("indexing.zig");
const translations_module = @import("translations.zig");
const components_module = @import("components.zig");
const interactive_module = @import("interactive.zig");
const transient_module = @import("transient.zig");

const Host = sandboxed_plugins.Host;
const sandboxed_plugins_max = sandboxed_plugins.sandboxed_plugins_max;
const heap_for = sandboxed_plugins.heap_for;

/// Unloads everything and loads every enabled plugin again from its row and file:
/// at start, and after any change to the plugins. A plugin that no longer loads is
/// logged and left out; the others run.
pub fn load_all(host: *Host, connection: *@import("../../lib/db.zig").Db) !void {
    std.debug.assert(connection.transaction_depth == 0);
    std.debug.assert(host.loaded.items.len <= sandboxed_plugins_max);

    for (host.loaded.items) |*loaded| {
        loaded.deinit();
    }

    host.loaded.clearRetainingCapacity();
    _ = host.translations_arena.reset(.retain_capacity);
    host.translations = .empty;
    host.stores = .empty;
    host.components = .empty;
    host.interactive = .empty;

    var arena_state = std.heap.ArenaAllocator.init(host.gpa);
    defer arena_state.deinit();

    const rows = try store.sandboxed_plugins.list(connection, arena_state.allocator());

    try fit_heap(host, rows);

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

        load_one(host, row) catch |err| {
            // One that does not fit said why already.
            if (err != error.DoesNotFit) {
                std.log.err("plugin {s} did not load: {t}", .{ row.name, err });
            }
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

    if (host.transient) |transient| {
        for (transient.plugins) |plugin| {
            load_transient(host, plugin) catch |err| {
                std.log.err("plugin {s} did not load: {t}", .{ plugin.row.name, err });
            };
        }
    }

    try indexing.reindex(host);

    if (host.languages) |languages| {
        try languages.set_installed(host.translations.items, try marked(host));
    }
}

/// The pool made large enough for every enabled plugin and every transient one, all
/// instantiated in one call chain: started again larger when it is not, while nothing
/// is loaded.
fn fit_heap(host: *Host, rows: []const store.sandboxed_plugins.Row) !void {
    std.debug.assert(host.loaded.items.len == 0);
    std.debug.assert(rows.len <= sandboxed_plugins_max);

    if (wasm.in_browser) {
        return;
    }

    var module_bytes: u64 = 0;
    var plugins: u64 = 0;

    for (rows) |row| {
        if (row.enabled) {
            module_bytes += host.files.bytes_of(row.hash);
            plugins += 1;
        }
    }

    if (host.transient) |transient| {
        for (transient.plugins) |plugin| {
            module_bytes += plugin.bytes.len;
            plugins += 1;
        }
    }

    const needed = heap_for(module_bytes, plugins);

    if (needed <= host.heap.len) {
        return;
    }

    host.runtime.deinit();
    host.gpa.free(host.heap);
    host.heap = &.{};
    host.heap = try host.gpa.alloc(u8, @intCast(needed));
    try host.runtime.init(host.heap, &invoke_module.imports, .{});

    std.debug.assert(host.heap.len >= needed);
}

/// A transient plugin, unless an installed one of its name is loaded.
fn load_transient(host: *Host, plugin: transient_module.Plugin) !void {
    std.debug.assert(plugin.bytes.len > 0);

    if (host.find_loaded(plugin.row.name) != null) {
        std.log.err("plugin {s} is installed here: --plugin {s} left out", .{
            plugin.row.name,
            plugin.row.name,
        });
        return;
    }

    try load_bytes(host, plugin.row, try host.gpa.dupe(u8, plugin.bytes));
    host.loaded.items[host.loaded.items.len - 1].transient = host.transient;
}

/// Each loaded plugin's marked messages, as its manifest lists them.
fn marked(host: *Host) ![]const @import("../languages.zig").Marked {
    std.debug.assert(host.loaded.items.len <= sandboxed_plugins_max);

    const Marked = @import("../languages.zig").Marked;
    const arena = host.index_arena.allocator();
    const out = try arena.alloc(Marked, host.loaded.items.len);

    for (host.loaded.items, out) |*loaded, *one| {
        one.* = .{
            .plugin = loaded.manifest.name,
            .messages = loaded.manifest.messages,
        };
    }

    return out;
}

fn load_one(host: *Host, row: store.sandboxed_plugins.Row) !void {
    std.debug.assert(row.name.len > 0);
    std.debug.assert(files_module.valid_hash(row.hash));

    try fits_here(host, row);
    try load_bytes(host, row, try host.files.read(host.gpa, row.hash));
}

/// Refuses to load a plugin this Publr cannot run (Publr was stepped back, or the item it
/// calls is gone), saying why; it stays installed, and loads again once it fits.
fn fits_here(host: *Host, row: store.sandboxed_plugins.Row) !void {
    std.debug.assert(row.manifest.len > 0);

    var arena_state = std.heap.ArenaAllocator.init(host.gpa);
    defer arena_state.deinit();

    const fit = @import("../../operations/plugin/fit.zig");
    const needs = std.json.parseFromSliceLeaky(fit.Needs, arena_state.allocator(), row.manifest, .{
        .ignore_unknown_fields = true,
    }) catch return error.Invalid;
    const refused = try fit.refusal(arena_state.allocator(), needs) orelse return;

    std.debug.assert(refused.message.len > 0);
    std.log.err("plugin {s} did not load: {s}", .{ row.name, refused.message });

    return error.DoesNotFit;
}

fn load_bytes(host: *Host, row: store.sandboxed_plugins.Row, bytes: []u8) !void {
    std.debug.assert(row.name.len > 0);
    std.debug.assert(bytes.len > 0);

    // Read before loading: the runtime rewrites the bytes it loads.
    const arena = host.translations_arena.allocator();
    const brought = try translations_module.of(arena, row.name, bytes);

    try host.translations.appendSlice(arena, brought);

    const stores_name = @import("../../sdk/plugin/manifest.zig").stores_section_name;
    const code = wasm.section.find(bytes, stores_name) catch null;

    if (code) |found| {
        if (found.len > 0) {
            try host.stores.append(arena, .{
                .plugin = try arena.dupe(u8, row.name),
                .code = try arena.dupe(u8, found),
            });
        }
    }

    try components_module.read(arena, row.name, bytes, &host.components);
    try interactive_module.read(arena, row.name, bytes, &host.interactive);

    const slot = try host.loaded.addOne(host.gpa);
    errdefer _ = host.loaded.pop();

    try slot.init(host.gpa, &host.runtime, row, bytes);
    slot.requests = &host.requests;
}
