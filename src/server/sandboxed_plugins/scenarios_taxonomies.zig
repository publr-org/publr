//! An installed plugin's taxonomies, on the test plugin `sampler`: declared under its name,
//! on its own type by `.taxonomies`, on greeter's by `.register_taxonomies` (a pattern, so
//! never the internal one), taken off and put back by an administrator, and the internal
//! one kept off the site.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../registry.zig");
const scenarios = @import("scenarios.zig");
const scenarios_remotes = @import("scenarios_remotes.zig");
const content_types = @import("../../operations/content_type.zig");
const taxonomies = @import("../../operations/taxonomy.zig");
const record = @import("../../operations/record.zig");
const on_type = @import("../../operations/taxonomy/on_type.zig");
const model = @import("../../model.zig");

const Scenario = scenarios.Scenario;
const admin = scenarios.admin;
const sampler = @embedFile("sandboxed_plugin_sampler");

/// Greeter and sampler added and enabled.
fn install(scenario: *Scenario) !void {
    std.debug.assert(sampler.len > 0);

    _ = try scenario.add(scenario.path);
    try scenarios_remotes.enable(scenario, "greeter");
    _ = try scenarios_remotes.put(scenario, "sampler.wasm", sampler);
    try scenarios_remotes.enable(scenario, "sampler");
}

fn has_field(def: model.content_type.Def, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (def.fields) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            return true;
        }
    }

    return false;
}

fn type_of(scenario: *Scenario, handle: []const u8) !model.content_type.Def {
    var reading = scenario.ctx(admin);

    std.debug.assert(handle.len > 0);

    return (try registry.SDK.dispatch(&reading, content_types.Get, .{
        .type = handle,
    })).definition;
}

test "an installed plugin's taxonomies go on its type and, by pattern, on greeter's" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    try install(&scenario);

    var reading = scenario.ctx(admin);
    const shelves = (try registry.SDK.dispatch(&reading, taxonomies.Get, .{
        .taxonomy = "sampler.shelf",
    })).definition;

    try std.testing.expectEqualStrings("Shelves", shelves.name);
    try std.testing.expectEqualStrings("sampler", shelves.owner);
    try std.testing.expect(shelves.public and shelves.hierarchical and !shelves.internal);
    try std.testing.expectEqual(@as(usize, 3), shelves.fields.len);
    try std.testing.expectEqualStrings("color", shelves.fields[2].kind);

    const flags = (try registry.SDK.dispatch(&reading, taxonomies.Get, .{
        .taxonomy = "sampler.flag",
    })).definition;

    try std.testing.expect(flags.internal and flags.single and !flags.public);

    const note = try type_of(&scenario, "sampler.sample_note");

    try std.testing.expect(has_field(note, "sampler_shelf"));
    try std.testing.expect(has_field(note, "sampler_flag"));

    // A `terms` field of a type's own form holds the taxonomy there: no sidebar copy.
    const review = try type_of(&scenario, "sampler.sample_review");

    try std.testing.expect(has_field(review, "shelves"));
    try std.testing.expect(!has_field(review, "sampler_shelf"));

    // `greeter.*` picks greeter's content types, never the internal taxonomy.
    const salutation = try type_of(&scenario, "greeter.salutation");

    try std.testing.expect(has_field(salutation, "sampler_shelf"));
    try std.testing.expect(!has_field(salutation, "sampler_flag"));

    const used = try on_type.used_by(&reading, "sampler.shelf");
    var by_sampler: u32 = 0;

    for (used) |user| {
        if (std.mem.eql(u8, user.by, "sampler")) {
            by_sampler += 1;
        }
    }

    try std.testing.expect(by_sampler >= 2);

    // Taken off greeter's type by an administrator: gone, and back once ticked again.
    var off = salutation;
    off.taxonomies = &.{.{
        .taxonomy = "sampler.shelf",
        .removed = true,
    }};
    const arena = scenario.harness.fixed.allocator();

    _ = try registry.SDK.dispatch(&reading, content_types.Update, .{
        .type = "greeter.salutation",
        .definition = try model.content_type.encode(arena, off),
    });
    const taken_off = try type_of(&scenario, "greeter.salutation");

    try std.testing.expect(!has_field(taken_off, "sampler_shelf"));

    off.taxonomies = &.{};
    _ = try registry.SDK.dispatch(&reading, content_types.Update, .{
        .type = "greeter.salutation",
        .definition = try model.content_type.encode(arena, off),
    });
    const put_back = try type_of(&scenario, "greeter.salutation");

    try std.testing.expect(has_field(put_back, "sampler_shelf"));
}

test "an internal taxonomy never reaches the site, whoever reads" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    try install(&scenario);

    var page = scenario.ctx(admin);

    page.delivery = true;

    const as_page = (try record.domain.definition.find(&page, "sampler.sample_note")).?;

    try std.testing.expect(has_field(as_page.def, "sampler_shelf"));
    try std.testing.expect(!has_field(as_page.def, "sampler_flag"));

    const listed = registry.SDK.call_json(&page, "term.list", "{\"taxonomy\":\"sampler.flag\"}");

    try std.testing.expectError(error.NotFound, listed);
    _ = try scenario.call(admin, "term.list", "{\"taxonomy\":\"sampler.flag\"}");
}

test "a plugin taxonomy's terms come back under its name, and GROQ filters on them" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    try install(&scenario);

    var writing = scenario.ctx(admin);
    const arena = scenario.harness.fixed.allocator();
    const term = @import("../../operations/term.zig");
    const top = try term.published(&writing, .{
        .taxonomy = "sampler.shelf",
        .document = "{\"name\":\"Top shelf\"}",
    });
    const note = try std.fmt.allocPrint(
        arena,
        "{{\"type\":\"sampler.sample_note\",\"document\":" ++
            "\"{{\\\"note\\\":\\\"Filed\\\",\\\"sampler_shelf\\\":[\\\"{s}\\\"]}}\"}}",
        .{top.id},
    );
    const created = try scenario.call(admin, "record.create", note);

    try std.testing.expect(std.mem.indexOf(u8, created, "\"id\"") != null);

    const query = try std.fmt.allocPrint(
        arena,
        "{{\"query\":\"*[_type == \\\"sampler.sample_note\\\" && $shelf in sampler_shelf]" ++
            "{{note}}\",\"params\":\"{{\\\"shelf\\\":\\\"{s}\\\"}}\"}}",
        .{top.id},
    );
    const found = try scenario.call(admin, "record.query", query);

    try std.testing.expect(std.mem.indexOf(u8, found, "Filed") != null);
}
