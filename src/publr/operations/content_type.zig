//! Content types: the shapes records are made of, as data. Definitions travel as JSON, both
//! into these operations and out of them.
const operation = @import("../operation.zig");

pub const namespace: operation.Namespace = .{
    .name = "content_type",
    .label = "Content types",
    .area = .site,
    .summary = "Content types: the shapes records are made of",
    .details =
    \\A content type is data, not code: a handle, names, a kind, whether it is public,
    \\and a list of fields (string, text, richtext, slug, email, url, boolean, integer,
    \\number, datetime, select, image, reference, terms, group, repeater). A `record`
    \\type holds any number of records, a `settings` type exactly one, a `component`
    \\none: fields are for other types to reuse. A `media` type's records are files
    \\(`media` commands); only core and plugins declare one. Definitions are passed as JSON. Editors
    \\may read types; changing them needs an admin. Public types are readable by anyone;
    \\private types only by signed-in users.
    ,
};

/// A content type as `content_type.list` shows it.
pub const Summary = @import("../model/content_type.zig").Summary;
/// One thing wrong with a definition, at its path.
pub const Problem = @import("../model/field.zig").Problem;

const new_definition =
    \\{"handle":"note","name":"Note","public":false,
    \\ "fields":[{"name":"title","label":"Title","kind":"string","validation":{"required":true}}]}
;

pub const example_definition =
    \\{"handle":"post","name":"Post","public":true,
    \\ "fields":[{"name":"title","label":"Title","kind":"string","validation":{"required":true}},
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
        \\to some of the registered statuses), `taxonomies` (the taxonomies it is filed
        \\under, `[{"taxonomy":"topics"}]`), and `fields`, which may be empty. Each
        \\field: `name`, `label`, `kind`, and optionally `filterable`, `searchable`, `many`
        \\(a list of values; any kind but slug and group), `validation` (the rules:
        \\`required`, `unique`, `min`, `max`, `min_len`, `max_len`, `hint`, ...), `options`
        \\(how it is edited: `choices`, `source`, `to`, `taxonomy`, `rows`, ...),
        \\`dimensions` (the site's dimensions it holds a value per combination of:
        \\`["language"]`, `["language","variation"]`; each also in `required_in` must be
        \\filled in every value going live, each in `empty_in` shows nothing when empty,
        \\the rest show the main value) and `fields` for group/repeater.
        \\Use `content_type validate` to see problems.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        definition: operation.Json,
    };
    pub const Out = struct {
        id: []const u8,
        handle: []const u8,
    };
    pub const example: In = .{
        .definition = .{
            .text = new_definition,
        },
    };
    pub const example_out: Out = .{
        .id = "7c2d9e4f1a8b3c5d6e7f8a9b",
        .handle = "note",
    };
    pub const field_docs: operation.Docs(In) = .{
        .definition = "The type definition as JSON",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .id = "The new type's id",
        .handle = "Its handle",
    };
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
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        type: []const u8,
        definition: operation.Json,
        drop_content: bool = false,
    };
    pub const Out = struct {
        id: []const u8,
        handle: []const u8,
        records_rewritten: u32,
        values_dropped: u32,
    };
    pub const example: In = .{
        .type = "post",
        .definition = .{
            .text = example_definition,
        },
    };
    pub const example_out: Out = .{
        .id = "7c2d9e4f1a8b3c5d6e7f8a9b",
        .handle = "post",
        .records_rewritten = 0,
        .values_dropped = 0,
    };
    pub const field_docs: operation.Docs(In) = .{
        .type = "Handle or id",
        .definition = "The complete new definition as JSON",
        .drop_content = "Delete the values of fields that the new definition removes",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .id = "The type's id",
        .handle = "Its handle",
        .records_rewritten = "Records whose values were converted or re-indexed",
        .values_dropped = "Values deleted for removed fields",
    };
};

pub const Get = struct {
    pub const name = "content_type.get";
    pub const description = "Read a content type's full definition";
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        type: []const u8,
    };
    pub const Out = struct {
        id: []const u8,
        /// The full definition as JSON, as `content_type.create` takes it.
        definition: operation.Json,
        created_at: i64,
        updated_at: i64,
    };
    pub const example: In = .{
        .type = "post",
    };
    pub const example_out: Out = .{
        .id = "7c2d9e4f1a8b3c5d6e7f8a9b",
        .definition = .{
            .text = example_definition,
        },
        .created_at = 1789650000000,
        .updated_at = 1789650000000,
    };
    pub const field_docs: operation.Docs(In) = .{
        .type = "Handle or id",
    };
};

pub const List = struct {
    pub const name = "content_type.list";
    pub const description = "List content types";
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        limit: u32 = 50,
        offset: u32 = 0,
    };
    pub const Out = struct {
        types: []const Summary,
        total: u32 = 0,
    };
    pub const field_docs: operation.Docs(In) = .{
        .limit = "How many at most; 50 when omitted, up to 200",
        .offset = "How many to pass over first, by name: the next page's start",
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .types = &.{.{
            .id = "7c2d9e4f1a8b3c5d6e7f8a9b",
            .handle = "post",
            .name = "Post",
            .kind = .record,
            .public = true,
            .system = false,
            .owner = "",
            .editor = "form",
            .fields = 2,
        }},
    };
    pub const output_docs: operation.Docs(Out) = .{
        .types = "Sorted by name; anonymous callers see public types only, an app's " ++
            "callers the types living in it or shared with it. `app` is where each lives, " ++
            "empty for a Global type",
        .total = "How many the caller sees in all",
    };
};

pub const Delete = struct {
    pub const name = "content_type.delete";
    pub const description = "Delete a content type; refuses while it has records unless forced";
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        type: []const u8,
        force: bool = false,
    };
    pub const Out = struct {
        deleted: bool,
        /// The handle it had.
        handle: []const u8,
        records_removed: u32,
        /// Its trash entry: `trash restore --id` brings it back.
        trash: []const u8 = "",
    };
    pub const example: In = .{
        .type = "page",
    };
    pub const example_out: Out = .{
        .deleted = true,
        .handle = "page",
        .records_removed = 0,
        .trash = "0190a1b2c3d40001a1b2c3d4",
    };
    pub const field_docs: operation.Docs(In) = .{
        .type = "Handle or id",
        .force = "Also delete every record of the type",
    };
};

pub const Validate = struct {
    pub const name = "content_type.validate";
    pub const description = "Check a JSON definition and list every problem without saving";
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        definition: operation.Json,
    };
    pub const Out = struct {
        valid: bool,
        problems: []const Problem,
    };
    pub const example: In = .{
        .definition = .{
            .text = "{\"handle\":\"Post\",\"name\":\"\",\"fields\":[]}",
        },
    };
    pub const example_out: Out = .{
        .valid = false,
        .problems = &.{
            .{
                .path = "handle",
                .message = "handle must be [a-z][a-z0-9_]*, up to 64 characters",
            },
            .{
                .path = "name",
                .message = "name must be 1 to 128 characters",
            },
        },
    };
};
