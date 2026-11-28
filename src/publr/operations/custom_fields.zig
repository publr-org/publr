//! Field schemas extending built-in entities, users and media, and the values they hold on
//! each: a schema is a `publr.content_type.Def`, as `content_type` takes one.
const operation = @import("../operation.zig");

/// A schema, as these operations take and answer it.
pub const Def = @import("../model/content_type.zig").Def;

pub const namespace: operation.Namespace = .{
    .name = "custom_fields",
    .label = "Custom fields",
    .area = .site,
    .summary = "Field schemas for users and media",
    .details = "Administrators define the additional fields shared by every user or media item. " ++
        "These schemas do not create content types or settings documents.",
};

pub const Values = values.Values;
pub const SaveValues = values.SaveValues;
const values = @import("custom_fields/values.zig");

const example_definition: Def = .{
    .handle = "user",
    .name = "User fields",
    .kind = .component,
    .title_field = "",
    .fields = &.{
        .{
            .name = "biography",
            .label = "Biography",
            .kind = "text",
        },
    },
};

pub const Get = struct {
    pub const name = "custom_fields.get";
    pub const description = "Read the field schema for users or media";
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        group: []const u8,
    };
    pub const Out = struct {
        /// The schema, as `custom_fields.update` takes it.
        definition: Def,
    };
    pub const example: In = .{
        .group = "user",
    };
    pub const example_out: Out = .{
        .definition = .{
            .handle = "user",
            .name = "User fields",
            .kind = .component,
            .title_field = "",
            .fields = &.{},
        },
    };
};

pub const Validate = struct {
    pub const name = "custom_fields.validate";
    pub const description = "Check a destination's field schema without saving";
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        group: []const u8,
        definition: Def,
    };
    pub const Out = @import("content_type.zig").Validate.Out;
    pub const example: In = .{
        .group = "user",
        .definition = example_definition,
    };
    pub const example_out: Out = .{
        .valid = true,
        .problems = &.{},
    };
};

pub const Update = struct {
    pub const name = "custom_fields.update";
    pub const description = "Replace the field schema for users or media";
    pub const kind: operation.Kind = .write;
    pub const In = Validate.In;
    pub const Out = Get.Out;
    pub const example = Validate.example;
    pub const example_out: Out = .{
        .definition = example_definition,
    };
};

pub const List = struct {
    pub const name = "custom_fields.list";
    pub const description = "List custom field groups";
    pub const kind: operation.Kind = .read;
    pub const In = struct {};
    pub const Item = struct {
        handle: []const u8,
        name: []const u8,
        active: bool,
    };
    pub const Out = struct {
        groups: []const Item,
    };
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
};

pub const Create = struct {
    pub const name = "custom_fields.create";
    pub const description = "Create a named custom field group";
    pub const find_words = "extra fields, shared fields, fields on many types, " ++
        "add fields to another type";
    pub const kind: operation.Kind = .write;
    pub const In = Update.In;
    pub const Out = Update.Out;
    pub const example: In = .{
        .group = "profile",
        .definition = .{
            .handle = "profile",
            .name = "Profile",
            .kind = .component,
            .fields = &.{},
        },
    };
    pub const example_out: Out = .{
        .definition = .{
            .handle = "profile",
            .name = "Profile",
            .kind = .component,
            .title_field = "",
            .fields = &.{},
        },
    };
};

pub const Delete = struct {
    pub const name = "custom_fields.delete";
    pub const description = "Delete a custom field group schema; it waits in the trash";
    pub const kind: operation.Kind = .write;
    pub const In = Get.In;
    pub const Out = struct {
        deleted: bool,
        /// Its trash entry: `trash restore --id` brings it back.
        trash: []const u8 = "",
    };
    pub const example: In = .{
        .group = "user",
    };
    pub const example_out: Out = .{
        .deleted = true,
        .trash = "0190a1b2c3d40001a1b2c3d4",
    };
};
