const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const content_type = @import("../../model/content_type.zig");
const field = @import("../../model/field.zig");
const types = @import("../../operations/content_type.zig");
const custom_fields = @import("../../operations/custom_fields.zig");

pub const Def = content_type.Def;

/// Create or update the content types declared in code, so the rows match the build.
pub const Declared = struct { owner: []const u8, def: Def };

pub fn apply(ctx: *sdk.Ctx, comptime defs: []const Declared) sdk.Error!void {
    std.debug.assert(ctx.caller == .system);
    comptime std.debug.assert(defs.len <= 64 * 64);

    inline for (defs) |declared| {
        try apply_one(ctx, declared);
    }
}

pub fn apply_all(ctx: *sdk.Ctx) sdk.Error!void {
    std.debug.assert(ctx.caller == .system);
    std.debug.assert(ctx.now_ms >= 0);

    try apply(ctx, registry.plugins.merged_content_types);

    inline for (registry.plugins.merged_custom_fields) |declared| {
        try apply_group(ctx, declared);
    }
}

/// Create or update a declared custom field group, its fields locked and owned by the
/// plugin, as a declared content type is.
fn apply_group(ctx: *sdk.Ctx, declared: Declared) sdk.Error!void {
    std.debug.assert(declared.def.handle.len > 0);
    std.debug.assert(declared.def.group.location.len > 0);

    const fields = try ctx.arena.alloc(field.Def, declared.def.fields.len);

    for (declared.def.fields, fields) |declared_field, *out| {
        out.* = declared_field;
        out.locked = true;
    }

    var def = declared.def;
    def.kind = .component;
    def.title_field = "";
    def.fields = fields;

    const wanted = try content_type.encode(ctx.arena, def);
    const existing = registry.SDK.dispatch(ctx, custom_fields.Get, .{
        .group = def.handle,
    }) catch |err| switch (err) {
        error.NotFound => {
            _ = try registry.SDK.dispatch(ctx, custom_fields.Create, .{
                .group = def.handle,
                .definition = wanted,
            });

            return;
        },
        else => return err,
    };

    const stored = try content_type.encode(ctx.arena, existing.definition);

    if (std.mem.eql(u8, stored, wanted)) {
        return;
    }

    _ = try registry.SDK.dispatch(ctx, custom_fields.Update, .{
        .group = def.handle,
        .definition = wanted,
    });
}

/// Create or update a declared type. Declared fields are locked and owned by the plugin;
/// fields added by hand on top of them are kept across redeclarations.
fn apply_one(ctx: *sdk.Ctx, declared: Declared) sdk.Error!void {
    std.debug.assert(declared.def.handle.len > 0);
    std.debug.assert(declared.def.fields.len > 0);

    const existing = try types.find_raw(ctx, declared.def.handle);
    const extras: []const field.Def = if (existing) |row|
        unlocked_of(row.def)
    else
        &.{};
    const fields = try ctx.arena.alloc(
        field.Def,
        declared.def.fields.len + extras.len,
    );

    for (declared.def.fields, 0..) |declared_field, index| {
        fields[index] = declared_field;
        fields[index].locked = true;
    }

    @memcpy(fields[declared.def.fields.len..], extras);

    var def = declared.def;
    def.system = true;
    def.owner = declared.owner;
    def.fields = fields;
    def.group = if (existing) |row| row.def.group else declared.def.group;

    const wanted = try content_type.encode(ctx.arena, def);

    if (existing) |row| {
        const stored = try content_type.encode(ctx.arena, row.def);

        if (std.mem.eql(u8, stored, wanted)) {
            return;
        }

        _ = try registry.SDK.dispatch(ctx, types.Update, .{
            .type = def.handle,
            .definition = wanted,
        });

        return;
    }

    _ = try registry.SDK.dispatch(ctx, types.Create, .{ .definition = wanted });
}

/// The fields of a stored type that were added by hand (not locked).
pub fn unlocked_of(def: Def) []const field.Def {
    std.debug.assert(def.handle.len > 0);
    std.debug.assert(def.fields.len <= field.fields_max);

    var first: u32 = 0;

    while (first < def.fields.len and def.fields[first].locked) : (first += 1) {}

    return def.fields[first..];
}

/// A type as a plugin declares it: public, with a slug from its note.
const declared_greeting = [_]Declared{.{ .owner = "greeter", .def = .{
    .handle = "greeting",
    .name = "Greeting",
    .public = true,
    .title_field = "note",
    .fields = &.{
        .{ .name = "note", .label = "Note", .kind = "string", .required = true },
        .{ .name = "slug", .label = "Slug", .kind = "slug", .options = .{ .source = "note" } },
    },
} }};

test "declared types: locked fields stay, hand-added fields survive a redeclaration" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try registry.SDK.bootstrap(&system);
    try apply(&system, &declared_greeting);

    var admin = harness.ctx(.{ .user = .{ .id = "u_ad", .roles = &.{"admin"} } });
    const greeting = try registry.SDK.dispatch(&admin, types.Get, .{ .type = "greeting" });
    try std.testing.expect(greeting.definition.system);
    try std.testing.expectEqualStrings("greeter", greeting.definition.owner);
    try std.testing.expect(greeting.definition.fields[0].locked);
    try std.testing.expect(greeting.definition.fields[1].locked);
    try std.testing.expect(greeting.definition.public);

    const with_extra =
        \\{"handle":"greeting","name":"Greeting","title_field":"note",
        \\ "public":true,
        \\ "fields":[{"name":"note","label":"Note","kind":"string","required":true,"locked":true},
        \\ {"name":"slug","label":"Slug","kind":"slug","options":{"source":"note"},"locked":true},
        \\ {"name":"mood","label":"Mood","kind":"string"}]}
    ;
    _ = try registry.SDK.dispatch(&admin, types.Update, .{
        .type = "greeting",
        .definition = with_extra,
    });
    const extended = try registry.SDK.dispatch(&admin, types.Get, .{ .type = "greeting" });
    try std.testing.expectEqual(@as(usize, 3), extended.definition.fields.len);
    try std.testing.expect(!extended.definition.fields[2].locked);

    const tampered =
        \\{"handle":"greeting","name":"Greeting","title_field":"note",
        \\ "public":true,
        \\ "fields":[{"name":"note","label":"Renamed","kind":"text","required":false},
        \\ {"name":"slug","label":"Slug","kind":"slug","options":{"source":"note"},"locked":true},
        \\ {"name":"mood","label":"Mood","kind":"string"}]}
    ;
    _ = try registry.SDK.dispatch(&admin, types.Update, .{
        .type = "greeting",
        .definition = tampered,
    });
    const still = try registry.SDK.dispatch(&admin, types.Get, .{ .type = "greeting" });
    try std.testing.expectEqualStrings("Note", still.definition.fields[0].label);

    var arranged = still.definition;
    arranged.group.presentation.labels = .beside;
    _ = try registry.SDK.dispatch(&admin, types.Update, .{
        .type = "greeting",
        .definition = try content_type.encode(admin.arena, arranged),
    });

    try apply(&system, &declared_greeting);
    const after = try registry.SDK.dispatch(&admin, types.Get, .{ .type = "greeting" });
    try std.testing.expectEqual(@as(usize, 3), after.definition.fields.len);
    try std.testing.expectEqualStrings("mood", after.definition.fields[2].name);
    try std.testing.expectEqual(.beside, after.definition.group.presentation.labels);

    const by_hand =
        \\{"handle":"mine","name":"Mine","system":true,
        \\ "fields":[{"name":"title","label":"T","kind":"string"}]}
    ;
    const refused = registry.SDK.dispatch(&admin, types.Create, .{ .definition = by_hand });
    try std.testing.expectError(error.Invalid, refused);
}
