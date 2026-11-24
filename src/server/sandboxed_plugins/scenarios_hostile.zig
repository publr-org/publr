//! A plugin that calls into Publr with requests that are wrong, on the test plugin `prober`:
//! addresses outside its memory, lengths that overflow, descriptions that lie or are cut
//! short, and every kind of value handed over wrong (a list, an enum, a value whose shape
//! comes with the data, a pointer, a union, a tree that is its own child), every way the
//! values of an apply can be wrong as a whole (more than one apply takes, no list, a name
//! that is none, an answer they cannot be laid back into), and every way a page handed over
//! to be drawn can be wrong. Every one ends that call with an error; the
//! server goes on answering.
const std = @import("std");
const scenarios = @import("scenarios.zig");
const scenarios_remotes = @import("scenarios_remotes.zig");
const wire = @import("../../sdk/plugin/wire.zig");

const Scenario = scenarios.Scenario;
const admin = scenarios.admin;
const module = @embedFile("sandboxed_plugin_prober");

test "requests that are wrong end with an error, never outside the plugin's memory" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    std.debug.assert(module.len > 0);

    _ = try scenarios_remotes.put(&scenario, "prober.wasm", module);
    try scenarios_remotes.enable(&scenario, "prober");

    const poked = try scenario.call(admin, "prober.poke", "{}");
    const Poked = struct {
        honest: u32,
        refused: []const u32,
        after: u32,
        forms: u32,
        page: u32,
        pages_refused: []const u32,
        page_unknown: u32,
    };
    const parsed = try std.json.parseFromSlice(Poked, std.testing.allocator, poked, .{});
    defer parsed.deinit();

    // The same call made honestly answers, before and after every wrong one.
    try std.testing.expectEqual(wire.ok, parsed.value.honest);
    try std.testing.expectEqual(@as(u32, 8), parsed.value.after);
    try std.testing.expectEqual(wire.ok, parsed.value.forms);
    try std.testing.expectEqual(@as(usize, 56), parsed.value.refused.len);

    for (parsed.value.refused) |code| {
        try std.testing.expectEqual(wire.code_of(error.Invalid), code);
    }

    // A page handed over to be drawn: markup alone is drawn, every wrong one refused.
    try std.testing.expectEqual(wire.ok, parsed.value.page);
    try std.testing.expectEqual(@as(usize, 15), parsed.value.pages_refused.len);
    try std.testing.expectEqual(wire.code_of(error.NotFound), parsed.value.page_unknown);

    for (parsed.value.pages_refused) |code| {
        try std.testing.expectEqual(wire.code_of(error.Invalid), code);
    }

    // And so does the server, to the same plugin.
    const again = try scenario.call(admin, "prober.poke", "{}");

    try std.testing.expectEqualStrings(poked, again);
}
