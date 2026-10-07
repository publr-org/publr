//! Field schemas extending built-in entities. Values belong to those entities, never records.
const std = @import("std");
const sdk = @import("../sdk.zig");
const model = @import("../model.zig");
const store = @import("../store.zig");
const registry = @import("../server/registry.zig");
const types = @import("content_type.zig");

pub const Destination = enum {
    user,
    media,

    pub fn key(destination: Destination) []const u8 {
        comptime std.debug.assert(@typeInfo(Destination).@"enum".fields.len == 2);
        return switch (destination) {
            .user => "custom_fields.user",
            .media => "custom_fields.media",
        };
    }

    pub fn definition(destination: Destination) model.content_type.Def {
        comptime std.debug.assert(@typeInfo(Destination).@"enum".fields.len == 2);
        return .{
            .handle = @tagName(destination),
            .name = if (destination == .user) "User fields" else "Media fields",
            .kind = .component,
            .title_field = "",
            .fields = &.{},
        };
    }
};

pub const namespace: sdk.operation.Namespace = .{
    .name = "custom_fields",
    .summary = "Field schemas for users and media",
    .details = "Administrators define the additional fields shared by every user or media item. " ++
        "These schemas do not create content types or settings documents.",
};
pub const operations = [_]type{ List, Get, Update, Validate, Create, Delete };
const example_definition =
    \\{"handle":"user","name":"User fields","kind":"component","title_field":"",
    \\ "fields":[{"name":"biography","label":"Biography","kind":"text"}]}
;

pub const Get = struct {
    pub const name = "custom_fields.get";
    pub const description = "Read the field schema for users or media";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct { group: []const u8 };
    pub const Out = struct { definition: model.content_type.Def };
    pub const example: In = .{ .group = "user" };
    pub const example_out: Out = .{ .definition = Destination.user.definition() };

    pub fn run(ctx: *sdk.Ctx, in: In, granted: *const sdk.Grant) sdk.Error!Out {
        std.debug.assert(granted.allows());
        try valid_handle(in.group);
        var def = definition(in.group);

        const stored = try store.field_groups.get(
            ctx.db,
            ctx.arena,
            .custom_fields,
            in.group,
        );

        if (stored) |group| {
            if (group.name.len > 0) def.name = group.name;
            def.fields = group.fields;
            def.group = group.options;
            if (group.name.len == 0 and std.meta.stringToEnum(Destination, in.group) != null) {
                def.group.location = try bound_location(
                    ctx.arena,
                    in.group,
                    group.options.location,
                );
            }
        } else {
            return error.NotFound;
        }

        return .{ .definition = def };
    }
};

pub const Validate = struct {
    pub const name = "custom_fields.validate";
    pub const description = "Check a destination's field schema without saving";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct { group: []const u8, definition: []const u8 };
    pub const Out = types.Validate.Out;
    pub const example: In = .{ .group = "user", .definition = example_definition };
    pub const example_out: Out = .{ .valid = true, .problems = &.{} };

    pub fn run(ctx: *sdk.Ctx, in: In, granted: *const sdk.Grant) sdk.Error!Out {
        std.debug.assert(granted.allows());

        if (in.definition.len > store.settings.value_len_max) {
            return error.Invalid;
        }

        const checked = try registry.SDK.dispatch(ctx, types.Validate, .{
            .definition = in.definition,
        });

        if (!checked.valid) {
            return checked;
        }

        const def = try model.content_type.decode(ctx.arena, in.definition);
        try valid_handle(in.group);

        const invalid = def.kind != .component or def.public or def.system or
            def.owner.len > 0 or !std.mem.eql(u8, def.handle, in.group) or def.url.len > 0 or
            !valid_location(def.group.location);

        if (invalid) {
            const problems = try ctx.arena.alloc(model.field.Problem, 1);

            problems[0] = .{
                .path = "",
                .message = "custom fields must be a private component schema " ++
                    "for the selected destination",
            };

            return .{ .valid = false, .problems = problems };
        }

        return checked;
    }
};

pub const Update = struct {
    pub const name = "custom_fields.update";
    pub const description = "Replace the field schema for users or media";
    pub const kind: sdk.operation.Kind = .write;
    pub const In = Validate.In;
    pub const Out = Get.Out;
    pub const example = Validate.example;
    pub const example_out: Out = .{ .definition = blk: {
        var def = Destination.user.definition();
        def.fields = &.{.{ .name = "biography", .label = "Biography", .kind = "text" }};
        break :blk def;
    } };

    pub fn run(ctx: *sdk.Ctx, in: In, granted: *const sdk.Grant) sdk.Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth > 0);
        const checked = try Validate.run(ctx, in, granted);

        if (!checked.valid) {
            return error.Invalid;
        }

        const def = try model.content_type.decode(ctx.arena, in.definition);
        var canonical = definition(in.group);
        canonical.name = def.name;
        canonical.fields = def.fields;
        canonical.group = def.group;
        const encoded = try model.content_type.encode(ctx.arena, canonical);

        if (encoded.len > store.settings.value_len_max) {
            return error.Invalid;
        }

        try store.field_groups.put(ctx.db, ctx.arena, .custom_fields, in.group, .{
            .name = canonical.name,
            .fields = canonical.fields,
            .options = canonical.group,
        });
        const created = std.mem.eql(u8, ctx.within, Create.name);

        ctx.notice(if (created) "custom_fields.created" else "custom_fields.updated", in.group);

        return .{ .definition = canonical };
    }
};

fn valid_handle(handle: []const u8) sdk.Error!void {
    const reserved = std.mem.eql(u8, handle, "new") or std.mem.eql(u8, handle, "create");

    if (handle.len == 0 or handle.len > 64 or !model.field.valid_name(handle) or reserved) {
        return error.Invalid;
    }

    std.debug.assert(model.field.valid_name(handle));
}

fn definition(handle: []const u8) model.content_type.Def {
    std.debug.assert(handle.len > 0);
    var def = Destination.user.definition();
    def.handle = handle;
    def.name = if (std.mem.eql(
        u8,
        handle,
        "user",
    )) "User fields" else if (std.mem.eql(
        u8,
        handle,
        "media",
    )) "Media fields" else handle;
    return def;
}

pub const List = struct {
    pub const name = "custom_fields.list";
    pub const description = "List custom field groups";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Item = struct { handle: []const u8, name: []const u8, active: bool };
    pub const Out = struct { groups: []const Item };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .groups = &.{
            .{
                .handle = "user",
                .name = "User fields",
                .active = true,
            },
        },
    };

    pub fn run(ctx: *sdk.Ctx, _: In, granted: *const sdk.Grant) sdk.Error!Out {
        std.debug.assert(granted.allows());
        const rows = try store.field_groups.list(ctx.db, ctx.arena, .custom_fields);
        const groups = try ctx.arena.alloc(Item, rows.len);

        for (rows, 0..) |row, index| {
            const got = try Get.run(ctx, .{ .group = row.owner }, granted);
            groups[index] = .{
                .handle = row.owner,
                .name = got.definition.name,
                .active = got.definition.group.active,
            };
        }

        return .{ .groups = groups };
    }
};

pub const Create = struct {
    pub const name = "custom_fields.create";
    pub const description = "Create a named custom field group";
    pub const kind: sdk.operation.Kind = .write;
    pub const In = Update.In;
    pub const Out = Update.Out;
    pub const example: In = .{
        .group = "profile",
        .definition = "{\"handle\":\"profile\",\"name\":\"Profile\"," ++
            "\"kind\":\"component\",\"fields\":[]}",
    };
    pub const example_out: Out = .{ .definition = .{
        .handle = "profile",
        .name = "Profile",
        .title_field = "",
        .kind = .component,
        .fields = &.{},
    } };

    pub fn run(ctx: *sdk.Ctx, in: In, granted: *const sdk.Grant) sdk.Error!Out {
        std.debug.assert(granted.allows());
        try valid_handle(in.group);

        if (try store.field_groups.get(ctx.db, ctx.arena, .custom_fields, in.group) != null) {
            return error.Conflict;
        }

        const rows = try store.field_groups.list(ctx.db, ctx.arena, .custom_fields);

        if (rows.len >= 256) {
            return error.Invalid;
        }

        return Update.run(ctx, in, granted);
    }
};

pub const Delete = struct {
    pub const name = "custom_fields.delete";
    pub const description = "Delete a custom field group schema";
    pub const kind: sdk.operation.Kind = .write;
    pub const destroys = true;
    pub const In = Get.In;
    pub const Out = struct { deleted: bool };
    pub const example: In = .{ .group = "user" };
    pub const example_out: Out = .{ .deleted = true };

    pub fn run(ctx: *sdk.Ctx, in: In, granted: *const sdk.Grant) sdk.Error!Out {
        std.debug.assert(granted.allows());
        try valid_handle(in.group);
        const found = try store.field_groups.get(ctx.db, ctx.arena, .custom_fields, in.group);

        if (found == null) {
            return error.NotFound;
        }

        try store.field_groups.delete(ctx.db, .custom_fields, in.group);
        ctx.notice("custom_fields.deleted", in.group);
        return .{ .deleted = true };
    }
};

fn valid_location(groups: model.field.conditions.Set) bool {
    std.debug.assert(groups.len <= model.field.conditions.groups_max);

    for (groups) |group| {
        for (group.rules) |rule| {
            const accepted = if (std.mem.eql(u8, rule.field, "destination"))
                std.meta.stringToEnum(Destination, rule.value) != null
            else if (std.mem.eql(u8, rule.field, "role"))
                registry.Roles.get(rule.value) != null
            else if (std.mem.eql(u8, rule.field, "media_type"))
                model.field.options.valid_media_type(rule.value)
            else
                false;
            if (!accepted) return false;
        }
    }

    return true;
}

test {
    _ = @import("custom_fields/tests.zig");
}

fn bound_location(
    arena: std.mem.Allocator,
    destination: []const u8,
    location: model.field.conditions.Set,
) sdk.Error!model.field.conditions.Set {
    const conditions = model.field.conditions;
    const Rules = []const conditions.Rule;
    std.debug.assert(location.len <= conditions.groups_max);
    std.debug.assert(std.meta.stringToEnum(Destination, destination) != null);
    const groups = try arena.alloc(conditions.Group, @max(1, location.len));

    for (groups, 0..) |*group, index| {
        const existing: Rules = if (location.len == 0) &.{} else location[index].rules;

        if (existing.len == conditions.rules_max) {
            return error.Invalid;
        }

        const rules = try arena.alloc(conditions.Rule, existing.len + 1);
        rules[0] = .{ .field = "destination", .value = destination };
        @memcpy(rules[1..], existing);
        group.* = .{ .rules = rules };
    }

    return groups;
}
