//! A user's custom fields: every custom field group that applies to the account is one
//! namespaced group of one document (`<group handle>.<field>`), read from and written to
//! `user_values` through the record machinery.
const operation = @import("../../operation.zig");
const user_shapes = @import("../user.zig");
const Problem = @import("../../model/field.zig").Problem;

pub const Get = struct {
    pub const name = "user.get";
    pub const description = "One account with its custom fields and their values";
    pub const details =
        \\Admins only. `fields` lists one group per custom field group that applies to the
        \\account (its destination is `user` and its role rules match); every field's path
        \\in `document` is `<group handle>.<field name>`.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        user: []const u8,
    };
    pub const Out = struct {
        user: user_shapes.Summary,
        /// The groups that apply, each with its fields, as JSON.
        fields: operation.Json,
        document: operation.Json,
    };
    pub const example: In = .{
        .user = "editor@example.com",
    };
    pub const example_out: Out = .{
        .user = .{
            .id = "9b1e7c3d5a2f4e6b8d0c1a3f",
            .email = "editor@example.com",
            .display_name = "Editor",
            .roles = &.{"editor"},
            .created_at = 1789646400000,
            .active = true,
        },
        .fields = .{
            .text = "[]",
        },
        .document = .{
            .text = "{}",
        },
    };
    pub const field_docs: operation.Docs(In) = .{
        .user = "The user's id or email",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .user = "The account",
        .fields = "The groups that apply, each with its fields",
        .document = "The values, as JSON, one object per group",
    };
};

pub const Validate = struct {
    pub const name = "user.validate";
    pub const description = "Check an account's custom field values without saving";
    pub const details = "Admins only. The same rules `user update --document` applies.";
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        user: []const u8,
        document: operation.Json,
    };
    pub const Out = struct {
        valid: bool,
        problems: []const Problem,
    };
    pub const example: In = .{
        .user = "editor@example.com",
        .document = .{
            .text = "{}",
        },
    };
    pub const example_out: Out = .{
        .valid = true,
        .problems = &.{},
    };
    pub const field_docs: operation.Docs(In) = .{
        .user = "The user's id or email",
        .document = "The values, as JSON, one object per group",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .valid = "Whether the document would be saved",
        .problems = "What was refused, by field path",
    };
};
