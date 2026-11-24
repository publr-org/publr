//! What a request cost in a plugin, on the test plugin `keeper`: its instructions, its
//! calls into core, how often it was entered, its instances and its memory are counted for
//! the request open on the host, and start again with the next one.
const std = @import("std");
const scenarios = @import("scenarios.zig");
const scenarios_remotes = @import("scenarios_remotes.zig");

const Scenario = scenarios.Scenario;
const admin = scenarios.admin;
const keeper_bytes = @embedFile("sandboxed_plugin_keeper");

test "a plugin's cost is counted for the request open, and the next one starts from nothing" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    _ = try scenarios_remotes.put(&scenario, "keeper.wasm", keeper_bytes);
    try scenarios_remotes.enable(&scenario, "keeper");

    const host = &scenario.host;
    const loaded = host.find_loaded("keeper").?;

    host.request_begin();

    try std.testing.expect(host.counted_total().idle());
    _ = try scenario.call(admin, "keeper.remember", "{\"value\":7}");

    const one = host.counted_total();

    try std.testing.expectEqual(@as(u32, 1), one.instances);
    try std.testing.expectEqual(@as(u32, 1), one.invocations);
    try std.testing.expectEqual(@as(u32, 0), one.host_calls);
    try std.testing.expect(one.instructions > 100);
    try std.testing.expect(one.memory_pages > 0);

    // Its own operation called from inside: one call into core, entered twice, the same
    // instance, and the nested work on the same count.
    _ = try scenario.call(admin, "keeper.relay", "{\"value\":20}");

    const two = host.counted_total();

    try std.testing.expectEqual(@as(u32, 1), two.instances);
    try std.testing.expectEqual(@as(u32, 3), two.invocations);
    try std.testing.expectEqual(@as(u32, 1), two.host_calls);
    try std.testing.expect(two.instructions > one.instructions * 2);

    // A top-level call told where core's memory stood, and named the request.
    try std.testing.expectEqualStrings("keeper.remember", host.counted.label());

    host.request_end();

    // The instance went with the request: what it used is kept until the next one begins.
    try std.testing.expect(loaded.instance == null);
    try std.testing.expectEqual(two.instructions, loaded.counted.instructions);

    host.request_begin();
    defer host.request_end();

    try std.testing.expect(host.counted_total().idle());
    try std.testing.expectEqualStrings("-", host.counted.label());
}
