//! An update's domains against the real thing, on the test plugins `courier` (asks for
//! api.example.com) and its update `courier_next` (asks for localhost instead).
const std = @import("std");
const registry = @import("../registry.zig");
const plugin_operations = @import("../../operations/plugin.zig");
const scenarios = @import("scenarios.zig");
const scenarios_remotes = @import("scenarios_remotes.zig");

const Scenario = scenarios.Scenario;
const admin = scenarios.admin;

/// What `courier.reach` answers: the domains its grant lists now.
fn reach(scenario: *Scenario) ![]const u8 {
    return scenario.call(admin, "courier.reach", "{}");
}

test "an update's new domains join the saved list on Allow; dropped ones leave" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    const courier = @embedFile("sandboxed_plugin_courier");

    _ = try scenarios_remotes.put(&scenario, "courier.wasm", courier);

    var enabling = scenario.ctx(.system);
    _ = try registry.SDK.dispatch(&enabling, plugin_operations.Enable, .{
        .names = &.{"courier"},
        .grants = &.{.{
            .key = "http.fetch",
            .on = true,
        }},
    });

    // The administrator adds their own team's server.
    var saving = scenario.ctx(.system);
    _ = try registry.SDK.dispatch(&saving, plugin_operations.SetGrant, .{
        .name = "courier",
        .key = "http.fetch",
        .domains = &.{ "api.example.com", "team.example" },
    });

    const added = try scenarios_remotes.put(
        &scenario,
        "courier-next.wasm",
        @embedFile("sandboxed_plugin_courier_next"),
    );

    try std.testing.expect(added.update);

    var reading = scenario.ctx(.system);
    const waiting = try registry.SDK.dispatch(&reading, plugin_operations.Get, .{
        .name = "courier",
    });
    const next = waiting.update.?;
    const fetch = for (next.requests) |request| {
        if (std.mem.eql(u8, request.key, "http.fetch")) {
            break request;
        }
    } else {
        return error.TestUnexpectedResult;
    };

    // The review: localhost is new; applying leaves the team's server and drops the old ask.
    try std.testing.expectEqual(@as(usize, 1), fetch.new_domains.len);
    try std.testing.expectEqualStrings("localhost", fetch.new_domains[0]);
    try std.testing.expectEqual(@as(usize, 2), fetch.domains.len);
    const before = "{\"domains\":[\"api.example.com\",\"team.example\"]}";

    try std.testing.expectEqualStrings(before, try reach(&scenario));

    var updating = scenario.ctx(.system);
    _ = try registry.SDK.dispatch(&updating, plugin_operations.Update, .{
        .name = "courier",
    });

    const after = "{\"domains\":[\"team.example\",\"localhost\"]}";

    try std.testing.expectEqualStrings(after, try reach(&scenario));

    // Rolled back: localhost leaves (the old version never asked for it); nothing joins.
    var rolling = scenario.ctx(.system);
    _ = try registry.SDK.dispatch(&rolling, plugin_operations.Rollback, .{
        .name = "courier",
    });

    try std.testing.expectEqualStrings("{\"domains\":[\"team.example\"]}", try reach(&scenario));
}
