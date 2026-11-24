//! What an installed plugin and core hand each other laid out, on the test plugin `sampler`:
//! values through its modifiers, a record it writes, and a call worked in steps whose memory
//! goes back as each ends.
const std = @import("std");
const scenarios = @import("scenarios.zig");
const scenarios_remotes = @import("scenarios_remotes.zig");

const Scenario = scenarios.Scenario;
const admin = scenarios.admin;
const module = @embedFile("sandboxed_plugin_sampler");

fn install(scenario: *Scenario) !void {
    std.debug.assert(module.len > 0);

    _ = try scenarios_remotes.put(scenario, "sampler.wasm", module);
    try scenarios_remotes.enable(scenario, "sampler");
}

test "installed modifiers take values as their own types; fields they do not declare stay" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    try install(&scenario);

    // The owner's side: sampler applies a number, its own modifier on `sampler.*` doubles it.
    const measured = try scenario.call(admin, "sampler.measure", "{\"text\":\"abc\"}");

    try std.testing.expectEqualStrings("{\"length\":6}", measured);

    // A title's modifier declares `id`, `title` and the record's `note`: what else a value
    // carries comes back as it went, in a batch of two.
    const values = "{\"name\":\"sampler.sample_note.title\",\"values\":[" ++
        "{\"id\":\"n1\",\"title\":\"Tea\",\"record\":{\"note\":\"abc\",\"shelf\":3}," ++
        "\"badge\":\"new\"},{\"id\":\"n2\",\"title\":\"Cup\",\"record\":{\"note\":\"abcde\"}}]}";
    const titled = try scenario.call(admin, "mod.apply", values);

    try std.testing.expect(std.mem.indexOf(u8, titled, "Note: Tea (3 characters)") != null);
    try std.testing.expect(std.mem.indexOf(u8, titled, "Note: Cup (5 characters)") != null);
    try std.testing.expect(std.mem.indexOf(u8, titled, "\"badge\":\"new\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, titled, "\"shelf\":3") != null);

    // A modifier declared for the whole batch (`publr.modify_all`) takes every value in one
    // call; the module was built with it and with a hook narrowed by `publr.hook.about`.
    const raised = try scenario.call(
        admin,
        "mod.apply",
        "{\"name\":\"sampler.batch.sizes\",\"values\":[1,2,40]}",
    );

    try std.testing.expect(std.mem.indexOf(u8, raised, "[2,3,41]") != null);

    // Values a modifier's type cannot hold go to it as JSON, and stay as they were.
    const mixed = try scenario.call(
        admin,
        "mod.apply",
        "{\"name\":\"sampler.length\",\"values\":[4,\"four\",{\"a\":1}]}",
    );

    try std.testing.expectEqualStrings("{\"values\":[8,\"four\",{\"a\":1}]}", mixed);
    try std.testing.expectError(
        error.Invalid,
        scenario.call(admin, "mod.apply", "{\"name\":\"sampler.length\",\"values\":\"[4]\"}"),
    );
}

test "a record an installed plugin writes as a struct is stored without its absent fields" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    try install(&scenario);

    _ = try scenario.call(admin, "sampler.note", "{\"note\":\"hello\"}");

    const found = try scenario.call(
        admin,
        "internal.find",
        "{\"plugin\":\"sampler\",\"kind\":\"tally\"}",
    );

    try std.testing.expect(std.mem.indexOf(u8, found, "{\"word\":\"HELLO\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, found, "checked_at") == null);
}

test "an installed call worked in scopes holds one step's memory, not the sum of its steps" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    try install(&scenario);

    // A hundred steps of 512 KiB are 50 MiB in all: three times what a plugin may hold.
    const stretched = try scenario.call(admin, "sampler.stretch", "{\"steps\":100,\"kib\":512}");

    try std.testing.expectEqualStrings("{\"steps\":100,\"last\":\"step 100 of 100\"}", stretched);
    try std.testing.expectError(
        error.Invalid,
        scenario.call(admin, "sampler.stretch", "{\"steps\":0,\"kib\":1}"),
    );
}

test "a field an installed plugin saves holding nothing is cleared, not kept" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    try install(&scenario);

    const user = "\"user\":\"admin@example.com\"";
    const kept = try scenario.call(
        admin,
        "sampler.motto",
        "{" ++ user ++ ",\"motto\":\"Keep notes\"}",
    );

    try std.testing.expectEqualStrings("{\"motto\":\"Keep notes\"}", kept);

    // The values go as they lie in the plugin: `null` arrives as `null`.
    const cleared = try scenario.call(admin, "sampler.motto", "{" ++ user ++ "}");

    try std.testing.expectEqualStrings("{\"motto\":null}", cleared);
}
