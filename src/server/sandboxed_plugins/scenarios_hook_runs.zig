//! An installed plugin's `on` hooks that fail, on the test plugin `printer`: each runs again
//! on its own as a job, and one whose tries run out is kept failed with why.
const std = @import("std");
const registry = @import("../registry.zig");
const job_queue = @import("../../store/job_queue.zig");
const job_define = @import("../../sdk/plugin/job_define.zig");
const plugin_log = @import("../../operations/plugin/log.zig");
const scenarios = @import("scenarios.zig");
const scenarios_remotes = @import("scenarios_remotes.zig");

const Scenario = scenarios.Scenario;
const admin = scenarios.admin;

/// How many of printer's Log lines say `text`.
fn logged(scenario: *Scenario, text: []const u8) !u32 {
    var reading = scenario.ctx(.system);
    const log = try registry.SDK.dispatch(&reading, plugin_log.Log, .{
        .name = "printer",
        .limit = 200,
    });
    var count: u32 = 0;

    std.debug.assert(text.len > 0);

    for (log.lines) |line| {
        const same = std.mem.eql(u8, line.line, text) and
            std.mem.eql(u8, line.call, "event:printer.print");

        count += @intFromBool(same);
    }

    return count;
}

test "an installed plugin's failing on hook runs again on its own, then shows failed" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    const module = @embedFile("sandboxed_plugin_printer");

    _ = try scenarios_remotes.put(&scenario, "printer.wasm", module);
    try scenarios_remotes.enable(&scenario, "printer");
    _ = try scenario.call(admin, "printer.print", "{\"label\":\"Box 4\",\"fails\":2}");
    _ = try scenario.call(admin, "printer.print", "{\"label\":\"Box 5\",\"fails\":99}");

    var worker = scenario.ctx(.system);

    // Two hooks on each print, each its own run.
    try std.testing.expectEqual(4, try registry.SDK.jobs.drain(&worker, 8));

    for (1..job_define.attempts_max) |_| {
        worker.now_ms += job_define.backoff_ms_max;
        _ = try registry.SDK.jobs.drain(&worker, 8);
    }

    // The copy was filed once a label: the failing send never ran it again.
    try std.testing.expectEqual(1, try logged(&scenario, "Filed a copy of Box 4"));
    try std.testing.expectEqual(1, try logged(&scenario, "Filed a copy of Box 5"));
    try std.testing.expectEqual(1, try logged(&scenario, "Sending Box 4, try 3"));
    try std.testing.expectEqual(1, try logged(&scenario, "Printed Box 4"));
    try std.testing.expectEqual(1, try logged(&scenario, "Sending Box 5, try 8"));
    // Both labels failed their first two tries.
    try std.testing.expectEqual(2, try logged(&scenario, "The hook on printer.print failed " ++
        "(try 2 of 8): The printer is offline."));
    try std.testing.expectEqual(1, try logged(&scenario, "The hook on printer.print failed " ++
        "for good after 8 tries: The printer is offline."));

    const listing = scenario.ctx(.system);
    const kept = try job_queue.list(listing.db, listing.arena, 8);

    try std.testing.expectEqual(1, kept.len);
    try std.testing.expectEqualStrings("printer", kept[0].plugin);
    try std.testing.expectEqualStrings("on:printer.print", kept[0].name);
    try std.testing.expectEqualStrings("failed", kept[0].state);
    try std.testing.expectEqual(job_define.attempts_max, kept[0].attempts);
    try std.testing.expect(std.mem.indexOf(u8, kept[0].input, "Box 5") != null);
}

test "an installed plugin's after hook on a list read adds its column's field to each row" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    const module = @embedFile("sandboxed_plugin_sampler");

    try scenario.harness.fixture.connection.exec("INSERT INTO users " ++
        "(id, email, display_name, created_at, updated_at) " ++
        "VALUES ('u_admin', 'counted@example.com', 'Counted', 0, 0)");
    _ = try scenarios_remotes.put(&scenario, "sampler.wasm", module);
    try scenarios_remotes.enable(&scenario, "sampler");
    _ = try scenario.call(admin, "sampler.note", "{\"note\":\"hello\"}");

    const listed = try scenario.call(admin, "user.list", "{}");

    // The sampler's NoteCount ran in the sandbox and answered the count back, under its name.
    const counted = "\"u_admin\":{\"sampler.notes\":1}";

    try std.testing.expect(std.mem.indexOf(u8, listed, counted) != null);
}
