//! The installed test plugin `tracker`: its `on` hooks hear `publr.errors.Failed` for each
//! error, nothing for a refusal, and a failed sign-in though the sign-in's write rolled back.
const std = @import("std");
const registry = @import("../registry.zig");
const plugin_log = @import("../../operations/plugin/log.zig");
const scenarios = @import("scenarios.zig");
const scenarios_remotes = @import("scenarios_remotes.zig");

const Scenario = scenarios.Scenario;
const admin = scenarios.admin;

/// How many of tracker's Log lines say `text`.
fn logged(scenario: *Scenario, text: []const u8) !u32 {
    var reading = scenario.ctx(.system);
    const log = try registry.SDK.dispatch(&reading, plugin_log.Log, .{
        .name = "tracker",
        .limit = 200,
    });
    var count: u32 = 0;

    std.debug.assert(text.len > 0);

    for (log.lines) |line| {
        count += @intFromBool(std.mem.eql(u8, line.line, text));
    }

    return count;
}

test "an installed tracker hears errors and failed sign-ins, never refusals" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    const module = @embedFile("sandboxed_plugin_tracker");

    _ = try scenarios_remotes.put(&scenario, "tracker.wasm", module);
    try scenarios_remotes.enable(&scenario, "tracker");
    _ = try scenario.call(admin, "tracker.break", "{\"how\":\"line\"}");
    try std.testing.expectError(error.Failed, scenario.call(
        admin,
        "tracker.break",
        "{\"how\":\"refuse\"}",
    ));
    try std.testing.expectError(error.Unavailable, scenario.call(
        admin,
        "tracker.break",
        "{\"how\":\"crash\"}",
    ));
    try std.testing.expectError(error.BadCredentials, scenario.call(
        .anonymous,
        "user.sign_in",
        "{\"email\":\"Nobody@example.com\",\"password\":\"wrong horse\"}",
    ));

    var worker = scenario.ctx(.system);

    try std.testing.expectEqual(3, try registry.SDK.events.drain(&worker, 8));
    try std.testing.expectEqual(1, try logged(&scenario, "Tracked tracker.break Logged: " ++
        "The disk is full by user"));
    try std.testing.expectEqual(1, try logged(&scenario, "Tracked tracker.break Unavailable: " ++
        " by user"));
    try std.testing.expectEqual(1, try logged(&scenario, "Sign-in failed for nobody@example.com"));
}
