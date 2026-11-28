//! An installed plugin is found as core is: its operation's `Find:` words reach `publr find`,
//! and its `Hint:` is shown when a field it names is added to a type, from its manifest.
const std = @import("std");
const registry = @import("../registry.zig");
const scenarios = @import("scenarios.zig");
const scenarios_remotes = @import("scenarios_remotes.zig");
const content_types = @import("../../operations/content_type.zig");
const find = @import("../../adapters/cli/find.zig");
const model = @import("../../model.zig");

const Scenario = scenarios.Scenario;
const admin = scenarios.admin;
const sampler = @embedFile("sandboxed_plugin_sampler");

test "an installed operation's Find: words reach find, and its Hint: a new field" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    _ = try scenario.add(scenario.path);
    _ = try scenarios_remotes.put(&scenario, "sampler.wasm", sampler);
    try scenarios_remotes.enable(&scenario, "sampler");

    var ctx = scenario.ctx(admin);
    const arena = ctx.arena;
    const all = try find.documents(registry.SDK, arena, ctx.sandboxed_plugins, "");
    const found = try find.rank(arena, all, "a catchphrase");

    try std.testing.expect(found.len > 0);
    try std.testing.expectEqualStrings("sampler motto", found[0].document.command);

    const definition = try std.json.parseFromSliceLeaky(model.content_type.Def, arena,
        \\{"handle":"team","name":"Team","fields":[
        \\{"name":"title","label":"Title","kind":"string"},
        \\{"name":"slogan","label":"Slogan","kind":"string"}]}
    , .{});
    const made = try registry.SDK.dispatch(&ctx, content_types.Create, .{
        .definition = definition,
    });

    try std.testing.expectEqual(@as(usize, 1), made.hints.len);
    try std.testing.expectEqualStrings("slogan", made.hints[0].field);
    try std.testing.expectEqualStrings("sampler motto", made.hints[0].see);
}
