//! A field on another plugin's type (rule 11a's third way), on the test plugins: sampler
//! places its parcel group, a weight of its own code-only kind, on greeter's salutations. The
//! value is in the record's own document, checked by sampler's kind, kept through a publish;
//! the type builder neither keeps the group on the type nor offers the kind.
const std = @import("std");
const registry = @import("../registry.zig");
const scenarios = @import("scenarios.zig");
const scenarios_remotes = @import("scenarios_remotes.zig");
const content_types = @import("../../operations/content_type.zig");
const model = @import("../../model.zig");

const Scenario = scenarios.Scenario;
const admin = scenarios.admin;
const sampler = @embedFile("sandboxed_plugin_sampler");
/// Sampler's second `.register_fields` group: its parcel.
const group = "sampler_1";

fn install(scenario: *Scenario) !void {
    std.debug.assert(sampler.len > 0);

    _ = try scenario.add(scenario.path);
    try scenarios_remotes.enable(scenario, "greeter");
    _ = try scenarios_remotes.put(scenario, "sampler.wasm", sampler);
    try scenarios_remotes.enable(scenario, "sampler");
}

fn field_named(def: model.content_type.Def, name: []const u8) ?model.field.Def {
    std.debug.assert(name.len > 0);

    for (def.fields) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            return field;
        }
    }

    return null;
}

/// `record.create`'s input for a salutation weighing `grams`.
fn create_of(arena: std.mem.Allocator, grams: i64) ![]const u8 {
    std.debug.assert(grams > std.math.minInt(i64));

    const weight = try std.json.Stringify.valueAlloc(arena, .{
        .grams = grams,
    }, .{});
    return std.json.Stringify.valueAlloc(arena, .{
        .type = "greeter.salutation",
        .document = .{
            .note = "Hello",
            .sampler_1 = .{
                .weight = weight,
            },
        },
    }, .{});
}

fn salutation(scenario: *Scenario) !model.content_type.Def {
    var reading = scenario.ctx(admin);

    return (try registry.SDK.dispatch(&reading, content_types.Get, .{
        .type = "greeter.salutation",
    })).definition;
}

test "an installed plugin's group on another's type: in the record, checked, never on the type" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    try install(&scenario);

    // The record's form reads the type with the group laid over it, of sampler's kind.
    const placed = field_named(try salutation(&scenario), group) orelse {
        return error.TestUnexpectedResult;
    };

    try std.testing.expectEqualStrings("group", placed.kind);
    try std.testing.expect(placed.locked);
    try std.testing.expectEqualStrings("sampler.weight", placed.fields[0].kind);

    // The kind is never offered in the type builder.
    const weight = registry.find_kind(&scenario.ctx(admin), "sampler.weight") orelse {
        return error.TestUnexpectedResult;
    };

    try std.testing.expect(weight.code_only);

    // Its value is the record's own, published with it, checked by sampler's kind (a struct
    // kept as JSON).
    const arena = scenario.harness.fixed.allocator();
    const made = try scenario.call(admin, "record.create", try create_of(arena, 1200));
    const Made = struct {
        id: []const u8,
    };
    const id = (try std.json.parseFromSliceLeaky(Made, arena, made, .{
        .ignore_unknown_fields = true,
    })).id;
    const publish = try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\"}}", .{id});

    _ = try scenario.call(admin, "record.publish", publish);

    const read = try scenario.call(admin, "record.get", publish);

    try std.testing.expect(std.mem.indexOf(u8, read, "1200") != null);

    const refused = scenario.call(admin, "record.create", try create_of(arena, -5));

    try std.testing.expectError(error.Invalid, refused);

    // Saved back by the type builder with the group in it: the type keeps only its own.
    var reading = scenario.ctx(admin);
    const def = try salutation(&scenario);

    _ = try registry.SDK.dispatch(&reading, content_types.Update, .{
        .type = "greeter.salutation",
        .definition = .{
            .text = try model.content_type.encode(arena, def),
        },
    });

    const raw = (try content_types.find_raw(&reading, "greeter.salutation")).?;

    try std.testing.expect(field_named(raw.def, group) == null);
    try std.testing.expect(field_named(try salutation(&scenario), group) != null);
}
