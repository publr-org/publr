//! Many installed plugins enabled in one call: each worked on in memory given back once it
//! is enabled, so the call takes about what its largest plugin takes, not their sum.
const std = @import("std");
const registry = @import("../registry.zig");
const plugin_operations = @import("../../operations/plugin.zig");
const scenarios = @import("scenarios.zig");
const scenarios_remotes = @import("scenarios_remotes.zig");
const limits = @import("../../model/limits.zig");
const store = @import("../../store.zig");
const sandboxed = @import("../sandboxed_plugins.zig");

const Scenario = scenarios.Scenario;

const Module = struct {
    name: []const u8,
    bytes: []const u8,
};

const modules = [_]Module{
    .{
        .name = "sampler",
        .bytes = @embedFile("sandboxed_plugin_sampler"),
    },
    .{
        .name = "greeter",
        .bytes = @embedFile("sandboxed_plugin_greeter"),
    },
    .{
        .name = "farewell",
        .bytes = @embedFile("sandboxed_plugin_farewell"),
    },
    .{
        .name = "prices",
        .bytes = @embedFile("sandboxed_plugin_prices"),
    },
    .{
        .name = "courier",
        .bytes = @embedFile("sandboxed_plugin_courier"),
    },
    .{
        .name = "digest",
        .bytes = @embedFile("sandboxed_plugin_digest"),
    },
    .{
        .name = "postcard",
        .bytes = @embedFile("sandboxed_plugin_postcard"),
    },
    .{
        .name = "printer",
        .bytes = @embedFile("sandboxed_plugin_printer"),
    },
    .{
        .name = "restock",
        .bytes = @embedFile("sandboxed_plugin_restock"),
    },
    .{
        .name = "supplier",
        .bytes = @embedFile("sandboxed_plugin_supplier"),
    },
    .{
        .name = "till",
        .bytes = @embedFile("sandboxed_plugin_till"),
    },
    .{
        .name = "tracker",
        .bytes = @embedFile("sandboxed_plugin_tracker"),
    },
    .{
        .name = "shelf",
        .bytes = @embedFile("sandboxed_plugin_shelf"),
    },
};

test "a dozen installed plugins enabled in one call take about one's memory, all run at once" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    var names: [modules.len][]const u8 = undefined;

    for (modules, &names) |module, *name| {
        const file = try std.fmt.allocPrint(std.testing.allocator, "{s}.wasm", .{module.name});
        defer std.testing.allocator.free(file);

        name.* = (try scenarios_remotes.put(&scenario, file, module.bytes)).name;
    }

    // One request's arena, as a server gives each request.
    const request = try std.testing.allocator.alloc(u8, limits.request_arena_bytes);
    defer std.testing.allocator.free(request);

    var fixed: std.heap.FixedBufferAllocator = .init(request);
    var enabling = scenario.ctx(.system);

    enabling.arena = fixed.allocator();

    const enabled = try registry.SDK.dispatch(&enabling, plugin_operations.Enable, .{
        .names = &names,
    });

    try std.testing.expectEqual(modules.len, enabled.plugins.len);

    for (enabled.plugins) |plugin| {
        try std.testing.expect(plugin.enabled);
    }

    // Each plugin's working memory went back: the call kept about one plugin's worth.
    var largest: u32 = 0;

    for (names) |name| {
        largest = @max(largest, try store.sandboxed_plugins.manifest_bytes(enabling.db, name));
    }

    const one_plugin = plugin_operations.Enable.enable_bytes +
        plugin_operations.Enable.manifest_factor * largest;

    try std.testing.expect(fixed.end_index < one_plugin + (1 << 20));

    // Every one of them instantiated at once, as a call chain through them all holds them:
    // the sandbox's pool was sized from their modules.
    var module_bytes: u64 = 0;

    for (modules) |module| {
        module_bytes += module.bytes.len;
    }

    try std.testing.expect(scenario.host.heap.len >= sandboxed.heap_for(module_bytes, 0));
    try std.testing.expectEqual(modules.len, scenario.host.loaded.items.len);

    for (scenario.host.loaded.items) |*loaded| {
        _ = try loaded.ensure_instance();
    }
}
