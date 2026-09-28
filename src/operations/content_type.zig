const std = @import("std");
const sdk = @import("../sdk.zig");
const model = @import("../model.zig");
const record = @import("record.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const content_type = model.content_type;
const definition = record.domain.definition;
const definition_module = @import("document/definition.zig");
const Def = content_type.Def;

pub const namespace: sdk.operation.Namespace = .{
    .name = "content_type",
    .summary = "Content types: the shapes records are made of",
    .details =
    \\A content type is data, not code: a handle, names, a kind, whether it is public,
    \\and a list of fields (string, text, richtext, slug, email, url, boolean, integer,
    \\number, datetime, select, image, reference, terms, group, repeater). A `record`
    \\type holds any number of records, a `settings` type exactly one, a `component`
    \\none: fields are for other types to reuse. Definitions are passed as JSON. Editors
    \\may read types; changing them needs an admin. Public types are readable by anyone;
    \\private types only by signed-in users.
    ,
};

pub const Summary = definition_module.Summary;
pub const Problem = model.field.Problem;
pub const find = definition.find;
pub const find_raw = definition.find_raw;
pub const visible = definition.visible;
pub const visible_type = definition.visible_type;
pub const brief_of = definition.brief_of;

const new_definition =
    \\{"handle":"note","name":"Note","public":false,
    \\ "fields":[{"name":"title","label":"Title","kind":"string","required":true}]}
;
pub const example_definition =
    \\{"handle":"post","name":"Post","public":true,
    \\ "fields":[{"name":"title","label":"Title","kind":"string","required":true},
    \\ {"name":"slug","label":"Slug","kind":"slug","options":{"source":"title"}},
    \\ {"name":"body","label":"Body","kind":"richtext","searchable":true},
    \\ {"name":"related","label":"Related","kind":"reference","many":true,
    \\ "options":{"to":["post"]}}]}
;

pub const Create = struct {
    pub const name = "content_type.create";
    pub const description = "Create a content type from a JSON definition";
    pub const details =
        \\Admins only. The definition is a JSON object: `handle` (`[a-z][a-z0-9_]*`,
        \\unique), `name`, `kind` (`record`, `settings` or `component`,
        \\default `record`), optional `icon`, `public` (default false), `editor` (default
        \\`form`), `editor_config`, `title_field` (default `title`: records take their
        \\title from the field of that name when the type has one), `statuses` (restrict
        \\to some of the registered statuses), and `fields`, which may be empty. Each
        \\field: `name`, `label`, `kind`, and optionally `required`, `filterable`,
        \\`searchable`, `many` (a list of values; any kind but slug and group),
        \\`options` (`min`, `max`, `min_len`, `max_len`, `choices`,
        \\`source`, `to`, `taxonomy`, `rows`) and `fields` for group/repeater. Use
        \\`content_type validate` to see problems.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { definition: []const u8 };
    pub const Out = struct { id: []const u8, handle: []const u8 };
    pub const example: In = .{ .definition = new_definition };
    pub const example_out: Out = .{ .id = "7c2d9e4f1a8b3c5d6e7f8a9b", .handle = "note" };
    pub const field_docs: sdk.operation.Docs(In) = .{ .definition = "The type definition as JSON" };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .id = "The new type's id",
        .handle = "Its handle",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.definition.len > content_type.definition_bytes_max + 1) {
            return error.Invalid;
        }

        const row = try definition.create(ctx, in.definition);

        return .{ .id = row.id, .handle = row.def.handle };
    }
};

pub const Update = struct {
    pub const name = "content_type.update";
    pub const description = "Change a content type's definition; existing records follow";
    pub const details =
        \\Admins only. Takes the type by handle or id and the full new definition (see
        \\`content_type create`). What happens to existing records follows from the
        \\change: added fields need nothing; a removed field is refused while records
        \\hold values for it unless `drop_content` is true, which deletes those values;
        \\a field whose kind changes is converted row by row when the change is
        \\allowed (string to text, integer to number, single to many, ...) and every
        \\value fits, otherwise the update is refused as `conflict`; shape changes
        \\(reference/image/group/repeater to something else) are never conversions,
        \\remove and re-add instead. Toggling `searchable` re-indexes the field.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { type: []const u8, definition: []const u8, drop_content: bool = false };
    pub const Out = struct {
        id: []const u8,
        handle: []const u8,
        records_rewritten: u32,
        values_dropped: u32,
    };
    pub const example: In = .{ .type = "post", .definition = example_definition };
    pub const example_out: Out = .{
        .id = "7c2d9e4f1a8b3c5d6e7f8a9b",
        .handle = "post",
        .records_rewritten = 0,
        .values_dropped = 0,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .type = "Handle or id",
        .definition = "The complete new definition as JSON",
        .drop_content = "Delete the values of fields that the new definition removes",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .id = "The type's id",
        .handle = "Its handle",
        .records_rewritten = "Records whose values were converted or re-indexed",
        .values_dropped = "Values deleted for removed fields",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.type.len > 64 << 10) {
            return error.Invalid;
        }

        const updated = try definition.update(ctx, in.type, in.definition, in.drop_content);

        return .{
            .id = updated.id,
            .handle = updated.handle,
            .records_rewritten = updated.rewritten,
            .values_dropped = updated.dropped,
        };
    }
};

pub const Get = struct {
    pub const name = "content_type.get";
    pub const description = "Read a content type's full definition";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct { type: []const u8 };
    pub const Out = struct { id: []const u8, definition: Def, created_at: i64, updated_at: i64 };
    pub const example: In = .{ .type = "post" };
    pub const example_out: Out = .{
        .id = "7c2d9e4f1a8b3c5d6e7f8a9b",
        .definition = content_type.test_post,
        .created_at = 1789650000000,
        .updated_at = 1789650000000,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{ .type = "Handle or id" };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        if (in.type.len > 64 << 10) {
            return error.Invalid;
        }

        std.debug.assert(granted.allows());

        const row = try definition.get(ctx, granted, in.type);

        return .{
            .id = row.id,
            .definition = row.def,
            .created_at = row.created_at,
            .updated_at = row.updated_at,
        };
    }
};

pub const List = struct {
    pub const name = "content_type.list";
    pub const description = "List content types";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct { types: []const Summary };
    pub const example: In = .{};
    pub const example_out: Out = .{ .types = &.{.{
        .id = "7c2d9e4f1a8b3c5d6e7f8a9b",
        .handle = "post",
        .name = "Post",
        .kind = .record,
        .public = true,
        .system = false,
        .owner = "",
        .editor = "form",
        .fields = 2,
    }} };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .types = "Sorted by name; anonymous callers see public types only",
    };

    pub fn run(ctx: *Ctx, _: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.now_ms >= 0);
        std.debug.assert(granted.allows());

        return .{ .types = try definition.list(ctx, granted) };
    }
};

pub const Delete = struct {
    pub const name = "content_type.delete";
    pub const description = "Delete a content type; refuses while it has records unless forced";
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { type: []const u8, force: bool = false };
    pub const Out = struct { deleted: bool, records_removed: u32 };
    pub const example: In = .{ .type = "page" };
    pub const example_out: Out = .{ .deleted = true, .records_removed = 0 };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .type = "Handle or id",
        .force = "Also delete every record of the type",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.type.len > 64 << 10) {
            return error.Invalid;
        }

        const deleted = try definition.delete(ctx, in.type, in.force);

        return .{ .deleted = deleted.deleted, .records_removed = deleted.removed };
    }
};

pub const Validate = struct {
    pub const name = "content_type.validate";
    pub const description = "Check a JSON definition and list every problem without saving";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct { definition: []const u8 };
    pub const Out = struct { valid: bool, problems: []const Problem };
    pub const example: In = .{
        .definition = "{\"handle\":\"Post\",\"name\":\"\",\"fields\":[]}",
    };
    pub const example_out: Out = .{ .valid = false, .problems = &.{
        .{ .path = "handle", .message = "handle must be [a-z][a-z0-9_]*, up to 64 characters" },
        .{ .path = "name", .message = "name must be 1 to 128 characters" },
    } };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.now_ms >= 0);

        if (in.definition.len > content_type.definition_bytes_max + 1) {
            return error.Invalid;
        }

        const report = try definition.validate(ctx, in.definition);

        return .{ .valid = report.valid, .problems = report.problems };
    }
};

pub const operations = [_]type{ Create, Update, Get, List, Delete, Validate };

test "definition input limits are checked before preparation and domain checks" {
    const registry = @import("../server/registry.zig");
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var ctx = harness.ctx(.system);
    const field_text = "{\"name\":\"name\",\"label\":\"Name\",\"kind\":\"string\"}";
    const too_many_fields = "{\"handle\":\"bad\",\"name\":\"Bad\",\"fields\":[" ++
        (field_text ++ ",") ** 64 ++ field_text ++ "]}";
    const too_many_statuses = "{\"handle\":\"bad\",\"name\":\"Bad\",\"fields\":[],\"statuses\":[" ++
        "\"draft\"," ** 64 ++ "\"draft\"]}";

    for ([_][]const u8{ too_many_fields, too_many_statuses }) |input_text| {
        try std.testing.expectError(error.Invalid, registry.SDK.dispatch(&ctx, Create, .{
            .definition = input_text,
        }));
        try std.testing.expectEqual(@as(u32, 0), ctx.db.transaction_depth);
    }
}
