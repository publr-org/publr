const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const registry = @import("../../app/registry.zig");
const types = @import("../content_type.zig");
const custom = @import("../custom_fields.zig");
const Get = custom.Get;
const Update = custom.Update;
const Validate = custom.Validate;
const Destination = custom.Destination;
const List = custom.List;
const Create = custom.Create;
const Delete = custom.Delete;

test "custom field schemas are isolated, bounded and administrator controlled" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var system = harness.ctx(.system);
    var visitor = harness.ctx(.anonymous);
    var editor = harness.ctx(.{ .user = .{ .id = "editor", .role = .editor } });
    try std.testing.expectError(error.Denied, registry.SDK.dispatch(&visitor, Get, Get.example));
    try std.testing.expectError(
        error.Denied,
        registry.SDK.dispatch(
            &editor,
            Update,
            Update.example,
        ),
    );
    _ = try registry.SDK.dispatch(&system, Update, Update.example);
    const saved = try registry.SDK.dispatch(&system, Get, .{ .group = "user" });
    try std.testing.expectEqualStrings("biography", saved.definition.fields[0].name);
    try std.testing.expectError(error.NotFound, registry.SDK.dispatch(
        &system,
        Get,
        .{ .group = "media" },
    ));
    try std.testing.expectEqual(
        @as(
            usize,
            0,
        ),
        (try registry.SDK.dispatch(
            &system,
            types.List,
            .{},
        )).types.len,
    );

    const invalid_schema =
        \\{"handle":"user","name":"User fields","kind":"component",
        \\ "fields":[{"name":"bad","label":"Bad","kind":"missing"}]}
    ;
    const public_schema =
        \\{"handle":"user","name":"User fields","public":true,"fields":[]}
    ;

    for ([_][]const u8{
        "{", "x" ** (store.settings.value_len_max + 1), public_schema, invalid_schema,
    }) |invalid| {
        try std.testing.expectError(error.Invalid, registry.SDK.dispatch(&system, Update, .{
            .group = "user",
            .definition = invalid,
        }));
    }

    const unchanged = try registry.SDK.dispatch(&system, Get, .{ .group = "user" });
    try std.testing.expectEqualStrings("biography", unchanged.definition.fields[0].name);
    const cleared = try model.content_type.encode(system.arena, Destination.user.definition());
    _ = try registry.SDK.dispatch(
        &system,
        Update,
        .{
            .group = "user",
            .definition = cleared,
        },
    );
    try std.testing.expectEqual(
        @as(
            usize,
            0,
        ),
        (try registry.SDK.dispatch(
            &system,
            Get,
            Get.example,
        )).definition.fields.len,
    );
}

test "named groups can share a destination and remain independent" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var system = harness.ctx(.system);
    _ = try registry.SDK.dispatch(&system, Create, Create.example);
    _ = try registry.SDK.dispatch(&system, Update, Update.example);
    try std.testing.expectEqual(
        @as(
            usize,
            2,
        ),
        (try registry.SDK.dispatch(
            &system,
            List,
            .{},
        )).groups.len,
    );
    try std.testing.expectError(
        error.Conflict,
        registry.SDK.dispatch(
            &system,
            Create,
            Create.example,
        ),
    );
    try std.testing.expectEqualStrings(
        "Profile",
        (try registry.SDK.dispatch(
            &system,
            Get,
            .{
                .group = "profile",
            },
        )).definition.name,
    );
    _ = try registry.SDK.dispatch(&system, Delete, .{ .group = "profile" });
    try std.testing.expectError(
        error.NotFound,
        registry.SDK.dispatch(
            &system,
            Get,
            .{
                .group = "profile",
            },
        ),
    );
    try std.testing.expectEqual(
        @as(
            usize,
            1,
        ),
        (try registry.SDK.dispatch(
            &system,
            List,
            .{},
        )).groups.len,
    );
    try std.testing.expectError(
        error.Invalid,
        registry.SDK.dispatch(
            &system,
            Get,
            .{
                .group = "../escape",
            },
        ),
    );
}

test "existing destination groups keep their location when opened as named groups" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var system = harness.ctx(.system);
    try store.field_groups.put(
        system.db,
        system.arena,
        .custom_fields,
        "user",
        .{
            .fields = &.{},
        },
    );
    const got = try registry.SDK.dispatch(&system, Get, .{ .group = "user" });
    try std.testing.expect(model.field_group.applies(
        got.definition.group,
        .{
            .destination = .user,
        },
    ));
    try std.testing.expect(!model.field_group.applies(
        got.definition.group,
        .{
            .destination = .media,
        },
    ));
    var invalid = got.definition;
    invalid.group.location = &.{.{ .rules = &.{.{ .field = "destination", .value = "unknown" }} }};
    try std.testing.expectError(error.Invalid, registry.SDK.dispatch(&system, Update, .{
        .group = "user",
        .definition = try model.content_type.encode(system.arena, invalid),
    }));
}
