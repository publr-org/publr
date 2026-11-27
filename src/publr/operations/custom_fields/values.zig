//! A field group's values on one account: what `publr.fields.get` and `publr.fields.save`
//! call, compiled in or installed. From a plugin's code they reach only its own groups
//! (`<plugin>`, `<plugin>_1`, ...), with no grant asked; wherever the group is placed, so a
//! plugin's location rule may read its own group to decide. A save changes the group's
//! fields only; every other group's values stay. With no plugin running, whoever reads or
//! changes accounts names any group.
const operation = @import("../../operation.zig");

const example_values = "{\"motto\":\"Keep notes\"}";

pub const Values = struct {
    pub const name = "custom_fields.values";
    pub const description = "A field group's values on one account";
    pub const details =
        \\From a plugin's code: its own group (`group` left out names `<plugin>`), on the
        \\account wherever the group is placed, with no grant asked. With no plugin running,
        \\whoever reads accounts names any group.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        user: []const u8,
        group: ?[]const u8 = null,
    };
    pub const Out = struct {
        values: operation.Json,
    };
    pub const example: In = .{
        .user = "admin@example.com",
        .group = "sampler",
    };
    pub const example_out: Out = .{
        .values = .{
            .text = example_values,
        },
    };
    pub const field_docs: operation.Docs(In) = .{
        .user = "The account's id or email",
        .group = "The group's handle; a plugin's own when left out",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .values = "The group's values, a JSON object",
    };
};

pub const SaveValues = struct {
    pub const name = "custom_fields.save_values";
    pub const description = "Change a field group's values on one account";
    pub const details =
        \\The fields `values` names change, checked as every write is; the group's other
        \\fields and every other group stay. From a plugin's code: its own group, with no
        \\grant asked. With no plugin running, whoever changes accounts names any group.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        user: []const u8,
        group: ?[]const u8 = null,
        values: operation.Json,

        /// A field a plugin hands over holding nothing is `null` here, which clears it;
        /// left out, it would keep what it held.
        pub const absent_is_null = true;
    };
    pub const Out = struct {
        values: operation.Json,
    };
    pub const example: In = .{
        .user = "admin@example.com",
        .group = "sampler",
        .values = .{
            .text = example_values,
        },
    };
    pub const example_out: Out = .{
        .values = .{
            .text = example_values,
        },
    };
    pub const field_docs: operation.Docs(In) = .{
        .user = "The account's id or email",
        .group = "The group's handle; a plugin's own when left out",
        .values = "The fields to change, a JSON object",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .values = "The group's values as saved, a JSON object",
    };
};
