const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const content_type = @import("../../model/content_type.zig");
const field = @import("../../model/field.zig");
const types = @import("../../operations/content_type.zig");
const custom_fields = @import("../../operations/custom_fields.zig");
const taxonomies = @import("../../operations/taxonomy.zig");
const site_dimensions = @import("../../operations/dimensions.zig");
const model_dimension = @import("../../model/dimension.zig");

pub const Def = content_type.Def;

/// Create or update the content types declared in code, so the rows match the build.
pub const Declared = struct {
    owner: []const u8,
    def: Def,
    /// The dimensions of a plugin being installed, not yet the site's: its own fields may
    /// use their field options.
    dimensions: []const model_dimension.Declared = &.{},
};

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

    // Taxonomies first: the types filed under them name them.
    inline for (registry.native_plugins.merged_taxonomies) |declared| {
        try apply_taxonomy(ctx, declared);
    }

    try apply(ctx, registry.native_plugins.merged_content_types);

    inline for (registry.native_plugins.merged_custom_fields) |declared| {
        try apply_group(ctx, declared);
    }
}

/// Create or update a declared custom field group, its fields locked and owned by the
/// plugin, as a declared content type is.
pub fn apply_group(ctx: *sdk.Ctx, declared: Declared) sdk.Error!void {
    std.debug.assert(declared.def.handle.len > 0);
    std.debug.assert(declared.def.group.location.len > 0);

    const fields = try ctx.arena.alloc(field.Def, declared.def.fields.len);

    const applied = try wrapped_applied(ctx, declared.def.fields, declared.dimensions);

    for (applied, fields) |declared_field, *out| {
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
pub fn apply_one(ctx: *sdk.Ctx, declared: Declared) sdk.Error!void {
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

    const applied = try wrapped_applied(ctx, declared.def.fields, declared.dimensions);

    for (applied, 0..) |declared_field, index| {
        fields[index] = declared_field;
        fields[index].locked = true;
    }

    @memcpy(fields[declared.def.fields.len..], extras);

    var def = declared.def;
    def.system = true;
    def.owner = declared.owner;
    def.fields = fields;
    def.group = if (existing) |row| row.def.group else declared.def.group;
    // Its declared taxonomies, then what an administrator ticked or took off.
    def.taxonomies = if (existing) |row|
        try content_type.with_locked(ctx.arena, declared.def.taxonomies, row.def.taxonomies)
    else
        declared.def.taxonomies;

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

    _ = try registry.SDK.dispatch(ctx, types.Create, .{
        .definition = wanted,
    });
}

/// Create or update a declared taxonomy, as a declared type is: its fields locked and owned
/// by the plugin, fields added by hand kept.
pub fn apply_taxonomy(ctx: *sdk.Ctx, declared: Declared) sdk.Error!void {
    std.debug.assert(declared.def.handle.len > 0);
    std.debug.assert(declared.def.fields.len > 0);

    const existing = try taxonomies.find(ctx, declared.def.handle);

    if (existing) |row| {
        if (!std.mem.eql(u8, row.def.owner, declared.owner)) {
            return error.Conflict;
        }
    }

    const extras: []const field.Def = if (existing) |row| unlocked_of(row.def) else &.{};
    const fields = try ctx.arena.alloc(field.Def, declared.def.fields.len + extras.len);

    const applied = try wrapped_applied(ctx, declared.def.fields, declared.dimensions);

    for (applied, 0..) |declared_field, index| {
        fields[index] = declared_field;
        fields[index].locked = true;
    }

    @memcpy(fields[declared.def.fields.len..], extras);

    var def = declared.def;
    def.system = true;
    def.owner = declared.owner;
    def.fields = fields;

    const wanted = try content_type.encode(ctx.arena, def);

    if (existing) |row| {
        if (std.mem.eql(u8, try content_type.encode(ctx.arena, row.def), wanted)) {
            return;
        }

        _ = try registry.SDK.dispatch(ctx, taxonomies.Update, .{
            .taxonomy = def.handle,
            .definition = wanted,
        });

        return;
    }

    _ = try registry.SDK.dispatch(ctx, taxonomies.Create, .{
        .definition = wanted,
    });
}

/// `fields` with what each says through a dimension's field option (`.translatable =
/// .required`) made into how it holds that dimension's values, by the dimensions the site
/// has and those of the plugin `installing` them, at every level. An option no dimension
/// offers does nothing; a value the option does not take refuses.
pub fn wrapped_applied(
    ctx: *sdk.Ctx,
    fields: []const field.Def,
    installing: []const model_dimension.Declared,
) sdk.Error![]const field.Def {
    std.debug.assert(fields.len <= field.fields_max);
    std.debug.assert(installing.len <= model_dimension.dimensions_max);

    const site = site_dimensions.all(ctx);
    const out = try ctx.arena.dupe(field.Def, fields);

    for (out) |*def| {
        def.fields = try wrapped_applied(ctx, def.fields, installing);

        for (def.wrapped) |wrapped| {
            const dimension = offering(site, wrapped.option) orelse
                offering(installing, wrapped.option) orelse continue;
            const holds = model_dimension.holds_named(dimension.field, wrapped.value) orelse {
                return ctx.fail(.{
                    .name = "Invalid",
                    .status = 422,
                    .message = try std.fmt.allocPrint(
                        ctx.arena,
                        "field `{s}`: `.{s}` takes no `{s}`",
                        .{ def.name, wrapped.option, wrapped.value },
                    ),
                });
            };

            if (holds == .one or model_dimension.varies_by(def.dimensions, dimension.name)) {
                continue;
            }

            def.dimensions = try with(ctx.arena, def.dimensions, dimension.name);

            switch (holds) {
                .required => {
                    def.required_in = try with(ctx.arena, def.required_in, dimension.name);
                },
                .empty => def.empty_in = try with(ctx.arena, def.empty_in, dimension.name),
                .one, .fallback => {},
            }
        }
    }

    return out;
}

/// The site's dimension whose field option is named `option`.
fn offering(
    site: []const model_dimension.Declared,
    option: []const u8,
) ?model_dimension.Declared {
    std.debug.assert(option.len > 0);

    for (site) |dimension| {
        if (std.mem.eql(u8, dimension.field.name, option)) {
            return dimension;
        }
    }

    return null;
}

fn with(
    arena: std.mem.Allocator,
    names: []const []const u8,
    name: []const u8,
) sdk.Error![]const []const u8 {
    std.debug.assert(name.len > 0);

    const out = try arena.alloc([]const u8, names.len + 1);

    @memcpy(out[0..names.len], names);
    out[names.len] = name;

    return out;
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
const declared_greeting = [_]Declared{.{
    .owner = "greeter",
    .def = .{
        .handle = "greeting",
        .name = "Greeting",
        .public = true,
        .title_field = "note",
        .fields = &.{
            .{
                .validation = .{
                    .required = true,
                },
                .name = "note",
                .label = "Note",
                .kind = "string",
            },
            .{
                .name = "slug",
                .label = "Slug",
                .kind = "slug",
                .options = .{
                    .source = "note",
                },
            },
        },
    },
}};

test "declared types: locked fields stay, hand-added fields survive a redeclaration" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try registry.SDK.bootstrap(&system);
    try apply(&system, &declared_greeting);

    var admin = harness.ctx(.{
        .user = .{
            .id = "u_ad",
            .roles = &.{"admin"},
        },
    });
    const greeting = try registry.SDK.dispatch(&admin, types.Get, .{
        .type = "greeting",
    });
    try std.testing.expect(greeting.definition.system);
    try std.testing.expectEqualStrings("greeter", greeting.definition.owner);
    try std.testing.expect(greeting.definition.fields[0].locked);
    try std.testing.expect(greeting.definition.fields[1].locked);
    try std.testing.expect(greeting.definition.public);

    const with_extra =
        \\{"handle":"greeting","name":"Greeting","title_field":"note",
        \\ "public":true,
        \\ "fields":[{"name":"note","label":"Note","kind":"string",
        \\ "validation":{"required":true},"locked":true},
        \\ {"name":"slug","label":"Slug","kind":"slug","options":{"source":"note"},"locked":true},
        \\ {"name":"mood","label":"Mood","kind":"string"}]}
    ;
    _ = try registry.SDK.dispatch(&admin, types.Update, .{
        .type = "greeting",
        .definition = with_extra,
    });
    const extended = try registry.SDK.dispatch(&admin, types.Get, .{
        .type = "greeting",
    });
    try std.testing.expectEqual(@as(usize, 3), extended.definition.fields.len);
    try std.testing.expect(!extended.definition.fields[2].locked);

    const tampered =
        \\{"handle":"greeting","name":"Greeting","title_field":"note",
        \\ "public":true,
        \\ "fields":[{"name":"note","label":"Renamed","kind":"text",
        \\ "validation":{"required":false}},
        \\ {"name":"slug","label":"Slug","kind":"slug","options":{"source":"note"},"locked":true},
        \\ {"name":"mood","label":"Mood","kind":"string"}]}
    ;
    _ = try registry.SDK.dispatch(&admin, types.Update, .{
        .type = "greeting",
        .definition = tampered,
    });
    const still = try registry.SDK.dispatch(&admin, types.Get, .{
        .type = "greeting",
    });
    try std.testing.expectEqualStrings("Note", still.definition.fields[0].label);

    var arranged = still.definition;
    arranged.group.presentation.labels = .beside;
    _ = try registry.SDK.dispatch(&admin, types.Update, .{
        .type = "greeting",
        .definition = try content_type.encode(admin.arena, arranged),
    });

    try apply(&system, &declared_greeting);
    const after = try registry.SDK.dispatch(&admin, types.Get, .{
        .type = "greeting",
    });
    try std.testing.expectEqual(@as(usize, 3), after.definition.fields.len);
    try std.testing.expectEqualStrings("mood", after.definition.fields[2].name);
    try std.testing.expectEqual(.beside, after.definition.group.presentation.labels);

    const by_hand =
        \\{"handle":"mine","name":"Mine","system":true,
        \\ "fields":[{"name":"title","label":"T","kind":"string"}]}
    ;
    const refused = registry.SDK.dispatch(&admin, types.Create, .{
        .definition = by_hand,
    });
    try std.testing.expectError(error.Invalid, refused);
}
