//! A plugin's instance, on the test plugin `keeper`, which leaves a number in its module's
//! memory: inside a request one instance serves every call into the plugin, nested ones
//! too; nothing it kept is there for the next request; a trap drops it; and the work a
//! call nests in its own instance counts against that call's budget.
const std = @import("std");
const scenarios = @import("scenarios.zig");
const scenarios_remotes = @import("scenarios_remotes.zig");

const registry = @import("../registry.zig");
const records = @import("../../operations/record.zig");
const greeter_bytes = @embedFile("sandboxed_plugin_greeter");

const Scenario = scenarios.Scenario;
const admin = scenarios.admin;
const keeper_bytes = @embedFile("sandboxed_plugin_keeper");
const prober_bytes = @embedFile("sandboxed_plugin_prober");

const Remembered = struct {
    before: u32,
    inner: u32 = 0,
};

fn remembered(scenario: *Scenario, name: []const u8, value: u32) !Remembered {
    var buffer: [64]u8 = undefined;
    const input = try std.fmt.bufPrint(&buffer, "{{\"value\":{d}}}", .{value});
    const answer = try scenario.call(admin, name, input);
    const arena = scenario.harness.fixed.allocator();

    std.debug.assert(answer.len > 0);

    return std.json.parseFromSliceLeaky(Remembered, arena, answer, .{});
}

/// `keeper.remember`: the number the module's memory held before this call.
fn kept_before(scenario: *Scenario, value: u32) !u32 {
    std.debug.assert(value > 0);

    return (try remembered(scenario, "keeper.remember", value)).before;
}

fn with_keeper(scenario: *Scenario) !void {
    std.debug.assert(keeper_bytes.len > 0);

    _ = try scenarios_remotes.put(scenario, "keeper.wasm", keeper_bytes);
    try scenarios_remotes.enable(scenario, "keeper");

    std.debug.assert(scenario.host.find_loaded("keeper") != null);
}

test "one instance serves a request's calls, and nothing it kept reaches the next request" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    try with_keeper(&scenario);

    const loaded = scenario.host.find_loaded("keeper").?;

    // Outside a request each top-level call is one: the number never outlasts it.
    try std.testing.expectEqual(@as(u32, 0), try kept_before(&scenario, 5));
    try std.testing.expectEqual(@as(u32, 0), try kept_before(&scenario, 6));
    try std.testing.expect(loaded.instance == null);

    {
        scenario.host.request_begin();
        defer scenario.host.request_end();

        const first = try remembered(&scenario, "keeper.remember", 7);
        const second = try remembered(&scenario, "keeper.remember", 8);
        // A call the plugin makes of its own operation runs on the instance it runs on.
        const nested = try remembered(&scenario, "keeper.relay", 20);

        try std.testing.expectEqual(@as(u32, 0), first.before);
        try std.testing.expectEqual(@as(u32, 7), second.before);
        try std.testing.expectEqual(@as(u32, 8), nested.before);
        try std.testing.expectEqual(@as(u32, 20), nested.inner);
        try std.testing.expect(loaded.instance != null);
        try std.testing.expectEqual(@as(u32, 0), loaded.running);
    }

    // The request ended: its instance went with it, and the next request finds nothing.
    try std.testing.expect(loaded.instance == null);
    try std.testing.expectEqual(@as(u32, 0), scenario.host.requests);

    scenario.host.request_begin();
    defer scenario.host.request_end();

    try std.testing.expectEqual(@as(u32, 0), try kept_before(&scenario, 9));
}

test "a trap drops the instance: no call enters it again, the next gets a fresh one" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    try with_keeper(&scenario);

    const loaded = scenario.host.find_loaded("keeper").?;

    scenario.host.request_begin();
    defer scenario.host.request_end();

    _ = try remembered(&scenario, "keeper.remember", 7);
    try std.testing.expectError(error.Unavailable, scenario.call(admin, "keeper.crash", "{}"));
    try std.testing.expect(loaded.instance == null);
    try std.testing.expect(!loaded.spoiled);

    // Neither the 7 nor the 99 the crashing call wrote is there.
    try std.testing.expectEqual(@as(u32, 0), try kept_before(&scenario, 3));

    // A trap in a call nested in the plugin's own: while the outer call still runs on the
    // spoiled instance, nothing else enters it; then it is dropped with the outer call.
    const stumbled = try scenario.call(admin, "keeper.stumble", "{}");

    try std.testing.expectEqualStrings("{\"crashed\":true,\"refused\":true}", stumbled);
    try std.testing.expect(loaded.instance == null);
    try std.testing.expectEqual(@as(u32, 0), try kept_before(&scenario, 4));
}

test "work a call nests in its own instance counts against the call's budget" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    try with_keeper(&scenario);

    const rounds = "{\"rounds\":300000";

    // One spin, and two nested, fit a call's budget; sixty-four nested do not, though each
    // alone would.
    _ = try scenario.call(admin, "keeper.spin", rounds ++ "}");
    _ = try scenario.call(admin, "keeper.spin_nested", rounds ++ ",\"turn\":2}");
    try std.testing.expectError(
        error.Unavailable,
        scenario.call(admin, "keeper.spin_nested", rounds ++ ",\"turn\":64}"),
    );

    // The next call starts on a whole budget, and a fresh instance.
    _ = try scenario.call(admin, "keeper.spin", rounds ++ "}");
}

test "a kept instance answers as fresh ones do" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    std.debug.assert(prober_bytes.len > 0);

    _ = try scenarios_remotes.put(&scenario, "prober.wasm", prober_bytes);
    try scenarios_remotes.enable(&scenario, "prober");

    const fresh = try scenario.call(admin, "prober.poke", "{}");

    scenario.host.request_begin();
    defer scenario.host.request_end();

    // Every wrong request the prober makes, three times over on one instance.
    for (0..3) |_| {
        try std.testing.expectEqualStrings(fresh, try scenario.call(admin, "prober.poke", "{}"));
    }
}

test "a hook on a bulk write is entered once for all its records, each heard on its own" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    std.debug.assert(greeter_bytes.len > 0);

    _ = try scenarios_remotes.put(&scenario, "greeter.wasm", greeter_bytes);
    try scenarios_remotes.enable(&scenario, "greeter");

    for ([_][]const u8{ "alone", "first", "keep", "second", "third" }) |note| {
        var buffer: [64]u8 = undefined;
        const input = try std.fmt.bufPrint(&buffer, "{{\"note\":\"{s}\"}}", .{note});

        _ = try scenario.call(admin, "greeter.greet", input);
    }

    var people = scenario.ctx(admin);
    const listed = try registry.SDK.dispatch(&people, records.List, .{
        .type = "greeter.salutation",
        .order = .title_asc,
    });
    const loaded = scenario.host.find_loaded("greeter").?;
    const ids = listed.records;

    try std.testing.expectEqual(@as(usize, 5), ids.len);

    const before_one = loaded.entered;
    const one = try registry.SDK.dispatch(&people, records.TransitionMany, .{
        .transition = "trash",
        .ids = &.{ids[0].id},
    });
    const for_one = loaded.entered - before_one;
    const many = try registry.SDK.dispatch(&people, records.TransitionMany, .{
        .transition = "trash",
        .ids = &.{ ids[1].id, ids[2].id, ids[3].id, ids[4].id },
    });
    const for_many = loaded.entered - before_one - for_one;

    // Four records enter the plugin as often as one did; the one its hook keeps is refused
    // among them, and the other three move.
    try std.testing.expectEqual(@as(u32, 1), one.moved);
    try std.testing.expectEqual(@as(u32, 3), many.moved);
    try std.testing.expectEqualStrings(ids[2].id, many.failed[0].id);
    try std.testing.expect(for_one > 0);
    try std.testing.expectEqual(for_one, for_many);
}

test "a modifier out of its budget refuses the apply, and the operation that asked for it" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    try with_keeper(&scenario);

    const light = "{\"name\":\"keeper.load\",\"values\":[{\"rounds\":10}]}";
    const heavy = "{\"name\":\"keeper.load\",\"values\":[{\"rounds\":10},{\"rounds\":90000000}]}";
    const weighed = try scenario.call(admin, "keeper.weigh", "{\"rounds\":10}");

    try std.testing.expect(std.mem.indexOf(u8, weighed, "\"weight\":1395") != null);

    // Core's own apply: refused by name, never answered with the values as they came.
    var applying = scenario.ctx(admin);

    try std.testing.expectError(
        error.Failed,
        registry.SDK.call_json(&applying, "mod.apply", heavy),
    );
    try std.testing.expectEqualStrings("ModifierFailed", applying.failure.?.name);

    // The operation that asked for the value is refused with it: it never goes on with a
    // load nobody weighed.
    if (scenario.call(admin, "keeper.weigh", "{\"rounds\":90000000}")) |answered| {
        std.debug.print("answered {s}\n", .{answered});

        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expect(err == error.Failed or err == error.Unavailable);
    }

    // The next apply starts on a fresh instance and a whole budget.
    var again = scenario.ctx(admin);
    const fits = try registry.SDK.call_json(&again, "mod.apply", light);

    try std.testing.expect(std.mem.indexOf(u8, fits, "\"weight\":1395") != null);
}
