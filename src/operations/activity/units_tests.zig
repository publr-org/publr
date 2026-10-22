//! The units an Activity entry lists, heard `after` the writes that changed them
//! (`sdk.changed_units`): read from each write's input and answer, each placed where its
//! write started, so a write's own units come before what it set off inside.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const store = @import("../../store.zig");
const activity = @import("../activity.zig");
const content_type = @import("../content_type.zig");
const custom_fields = @import("../custom_fields.zig");
const record = @import("../record.zig");
const Put = @import("../project/put.zig").Put;

const SDK = registry.SDK;
const stored_rows = store.stored_rows;

const note_definition = "{\"handle\":\"note\",\"name\":\"Note\",\"fields\":[" ++
    "{\"name\":\"title\",\"label\":\"Title\",\"kind\":\"string\"}]}";

/// The units of the newest entry for `operation`.
fn units_of(ctx: *sdk.Ctx, operation: []const u8) ![]const []const u8 {
    std.debug.assert(operation.len > 0);

    const listed = try SDK.dispatch(ctx, activity.List, .{
        .operation = operation,
    });

    try std.testing.expect(listed.entries.len >= 1);

    return listed.entries[0].units;
}

fn expect_units(expected: []const []const u8, got: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, got.len);

    for (expected, got) |one, other| {
        try std.testing.expectEqualStrings(one, other);
    }
}

test "activity: a field group and a type by their handles, from the write's input or answer" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);

    _ = try SDK.dispatch(&system, custom_fields.Create, .{
        .group = "profile",
        .definition = "{\"handle\":\"profile\",\"name\":\"Profile\",\"kind\":\"component\"," ++
            "\"fields\":[]}",
    });
    try expect_units(&.{"field_group:profile"}, try units_of(&system, "custom_fields.create"));

    const note = try SDK.dispatch(&system, content_type.Create, .{
        .definition = note_definition,
    });

    try expect_units(&.{"content_type:note"}, try units_of(&system, "content_type.create"));

    // Deleted by its id: the unit still names it by the handle its answer gives.
    _ = try SDK.dispatch(&system, content_type.Delete, .{
        .type = note.id,
    });
    try expect_units(&.{"content_type:note"}, try units_of(&system, "content_type.delete"));
}

test "activity: project.put lists what it put in its order, before what landing set off" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);

    const note = try SDK.dispatch(&system, content_type.Create, .{
        .definition = note_definition,
    });
    const created = try SDK.dispatch(&system, record.Create, .{
        .type = "note",
        .document = "{\"title\":\"One\"}",
    });
    _ = try SDK.dispatch(&system, record.Publish, .{
        .id = created.id,
    });
    const type_rows = try stored_rows.read(
        system.db,
        system.arena,
        stored_rows.shape_of(.content_type),
        note.id,
    );
    const record_rows = try stored_rows.read(
        system.db,
        system.arena,
        stored_rows.shape_of(.record),
        created.id,
    );

    var admin = harness.ctx(.{
        .user = .{
            .id = "u_admin",
            .roles = &.{"admin"},
        },
    });

    _ = try SDK.dispatch(&admin, Put, .{
        .units = &.{
            .{
                .kind = "record",
                .id = created.id,
                .rows = "{}",
            },
            .{
                .kind = "content_type",
                .id = note.id,
                .rows = "{}",
            },
        },
    });

    const back = try SDK.dispatch(&admin, Put, .{
        .units = &.{
            .{
                .kind = "content_type",
                .id = note.id,
                .rows = type_rows,
            },
            .{
                .kind = "record",
                .id = created.id,
                .rows = record_rows,
            },
        },
    });
    const record_unit = try std.fmt.allocPrint(system.arena, "record:{s}", .{created.id});

    try std.testing.expectEqualStrings("note", back.put[0].handle);
    try std.testing.expectEqualStrings("", back.put[1].handle);
    try expect_units(&.{ "content_type:note", record_unit }, try units_of(&system, "project.put"));
}

test "activity: a record's own writes and a move over many, each record by its id" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);

    _ = try SDK.dispatch(&system, content_type.Create, .{
        .definition = note_definition,
    });

    const one = try SDK.dispatch(&system, record.Create, .{
        .type = "note",
        .document = "{\"title\":\"One\"}",
    });
    _ = try SDK.dispatch(&system, record.Publish, .{
        .id = one.id,
    });
    const two = try SDK.dispatch(&system, record.Create, .{
        .type = "note",
        .document = "{\"title\":\"Two\"}",
    });
    const one_unit = try std.fmt.allocPrint(system.arena, "record:{s}", .{one.id});
    const two_unit = try std.fmt.allocPrint(system.arena, "record:{s}", .{two.id});

    try expect_units(&.{two_unit}, try units_of(&system, "record.create"));

    // A save that changes nothing names nothing; one that parks an edit names the record.
    const same = try SDK.dispatch(&system, record.Save, .{
        .id = one.id,
        .document = "{\"title\":\"One\"}",
    });

    try std.testing.expectEqualStrings("unchanged", same.outcome);
    try expect_units(&.{}, try units_of(&system, "record.save"));

    const parked = try SDK.dispatch(&system, record.Save, .{
        .id = one.id,
        .document = "{\"title\":\"One, edited\"}",
    });

    try std.testing.expectEqualStrings("changes_saved", parked.outcome);
    try expect_units(&.{one_unit}, try units_of(&system, "record.save"));

    // Many at once: each record its transition event names.
    _ = try SDK.dispatch(&system, record.TransitionMany, .{
        .transition = "trash",
        .ids = &.{ one.id, two.id },
    });
    try expect_units(&.{ one_unit, two_unit }, try units_of(&system, "record.transition_many"));
}
