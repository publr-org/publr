//! Many calls on one long-lived host: each starts from the module's own memory, so nothing
//! an earlier call left behind (a heap grown and fragmented) reaches the next.
const std = @import("std");
const scenarios = @import("scenarios.zig");
const registry = @import("../registry.zig");
const plugin_operations = @import("../../operations/plugin.zig");

const Scenario = scenarios.Scenario;

const calls_count: u32 = 1_000;

test "a thousand calls on one host each start clean and none fails" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    const added = try scenario.add(scenario.path);
    var enabling = scenario.ctx(.system);

    _ = try registry.SDK.dispatch(&enabling, plugin_operations.Enable, .{
        .names = &.{added.name},
    });

    try std.testing.expectEqual(@as(usize, 1), scenario.host.loaded.items.len);

    const loaded = &scenario.host.loaded.items[0];

    for (0..calls_count) |_| {
        const answer = try scenario.call(scenarios.admin, "greeter.count", "{}");

        try std.testing.expect(std.mem.indexOf(u8, answer, "\"total\"") != null);
        try std.testing.expect(loaded.instance == null);
        try std.testing.expectEqual(@as(u32, 0), loaded.running);
    }
}
