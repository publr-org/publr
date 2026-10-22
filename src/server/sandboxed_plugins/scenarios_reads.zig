//! What an installed plugin reads across types and taxonomies, on the test plugin `digest`:
//! each type by its own grant, terms of private taxonomies and drafts by their flags.
const std = @import("std");
const registry = @import("../registry.zig");
const plugin_operations = @import("../../operations/plugin.zig");
const grant_tests = @import("../../operations/record/grant_tests.zig");
const scenarios = @import("scenarios.zig");
const scenarios_remotes = @import("scenarios_remotes.zig");

const Scenario = scenarios.Scenario;
const admin = scenarios.admin;

const Read = struct {
    listed: []const []const u8,
    queried: []const []const u8,
    terms: []const []const u8,
};

fn read(scenario: *Scenario) !Read {
    const arena = scenario.harness.fixed.allocator();
    const answer = try scenario.call(admin, "digest.read", "{\"week\":1}");

    std.debug.assert(answer.len > 0);

    return std.json.parseFromSliceLeaky(Read, arena, answer, .{
        .ignore_unknown_fields = true,
    });
}

fn joined(names: []const []const u8, arena: std.mem.Allocator) ![]const u8 {
    std.debug.assert(names.len <= 16);

    return std.mem.join(arena, ", ", names);
}

const Flags = struct {
    on: bool = true,
    private: bool = false,
    drafts: bool = false,
};

fn set_terms(scenario: *Scenario, flags: Flags) !void {
    var system = scenario.ctx(.system);

    std.debug.assert(flags.on or !flags.private);

    _ = try registry.SDK.dispatch(&system, plugin_operations.SetGrant, .{
        .name = "digest",
        .key = "terms.read",
        .on = flags.on,
        .private = flags.private,
        .drafts = flags.drafts,
    });
}

test "installed, a plugin's reads answer each type and taxonomy by its own grant" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    var system = scenario.ctx(.system);

    try grant_tests.seed_posts_and_notes(&system);
    try grant_tests.seed_taxonomies(&system);
    const module = @embedFile("sandboxed_plugin_digest");

    _ = try scenarios_remotes.put(&scenario, "digest.wasm", module);
    try scenarios_remotes.enable(&scenario, "digest");

    const arena = scenario.harness.fixed.allocator();
    // terms.read asks for .private and .drafts: high, so it waits for a person.
    const first = try read(&scenario);

    try std.testing.expectEqualStrings(
        "Note draft, Note published, Post published",
        try joined(first.listed, arena),
    );
    try std.testing.expectEqualStrings(
        "Note draft, Note published, Post published",
        try joined(first.queried, arena),
    );
    try std.testing.expectEqual(@as(usize, 0), first.terms.len);

    try set_terms(&scenario, .{
        .on = true,
        .private = false,
        .drafts = false,
    });
    try std.testing.expectEqualStrings(
        "topics published",
        try joined((try read(&scenario)).terms, arena),
    );

    try set_terms(&scenario, .{
        .on = true,
        .private = true,
        .drafts = false,
    });
    try std.testing.expectEqualStrings(
        "desk published, topics published",
        try joined((try read(&scenario)).terms, arena),
    );

    try set_terms(&scenario, .{
        .on = true,
        .private = true,
        .drafts = true,
    });
    try std.testing.expectEqualStrings(
        "desk draft, desk published, topics draft, topics published",
        try joined((try read(&scenario)).terms, arena),
    );
}
