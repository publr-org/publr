//! Taxonomies: the classifications records are filed under. A taxonomy is the schema of its
//! terms, as a content type is the schema of its records; definitions travel as JSON, both
//! into these operations and out of them.
const operation = @import("../operation.zig");

pub const namespace: operation.Namespace = .{
    .name = "taxonomy",
    .label = "Taxonomies",
    .area = .content,
    .summary = "Taxonomies: the classifications records are filed under",
    .details =
    \\A taxonomy is the schema of its terms, as a content type is the schema of its
    \\records: a handle, a name, whether it is public, and the fields a term carries
    \\(a name, a slug, a colour, a cover image: any field kind but `terms`). A
    \\`hierarchical` taxonomy lets a term have a parent term; a flat one does not. A
    \\taxonomy never names types: a content type lists it in `taxonomies`, and each
    \\record then selects its terms in the editor's sidebar (or in a `terms` field of the
    \\form naming it). An `internal` taxonomy never reaches the site. Definitions are
    \\passed as JSON. Signed-in users may read taxonomies; changing them needs an admin.
    ,
};

/// A taxonomy as `taxonomy.list` shows it.
pub const Summary = @import("../model/content_type.zig").Summary;
/// One thing wrong with a definition, at its path.
pub const Problem = @import("../model/field.zig").Problem;

const new_definition =
    \\{"handle":"regions","name":"Regions","title_field":"name",
    \\ "fields":[{"name":"name","label":"Name","kind":"string","validation":{"required":true}}]}
;

pub const example_definition =
    \\{"handle":"topics","name":"Topics","public":true,"hierarchical":true,
    \\ "title_field":"name",
    \\ "fields":[{"name":"name","label":"Name","kind":"string","validation":{"required":true}},
    \\ {"name":"slug","label":"Slug","kind":"slug","options":{"source":"name"}}]}
;

const example_id = "d4e5f60718293a4b5c6d7e8f";

pub const Create = struct {
    pub const name = "taxonomy.create";
    pub const description = "Create a taxonomy from a JSON definition";
    pub const details =
        \\Admins only. The definition takes the keys of a content type definition
        \\(`handle`, `name`, `public`, `title_field`, `statuses`, `fields`; see
        \\`content_type create`) plus `hierarchical` (default false: terms may have a
        \\parent term). Its kind is always `record`, it has no `url`, and no field of
        \\kind `terms`. Use `taxonomy validate` to see problems.
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
        .id = example_id,
        .handle = "regions",
    };
    pub const field_docs: operation.Docs(In) = .{
        .definition = "The taxonomy definition as JSON",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .id = "The new taxonomy's id",
        .handle = "Its handle",
    };
};

pub const Update = struct {
    pub const name = "taxonomy.update";
    pub const description = "Change a taxonomy's definition; existing terms follow";
    pub const details =
        \\Admins only. Takes the taxonomy by handle or id and the full new definition.
        \\Existing terms follow the change as records follow a content type change: a
        \\removed field is refused while terms hold values for it unless `drop_content`
        \\is true; a field whose kind changes is converted when every value fits. Turning
        \\`hierarchical` off is refused while any term has a parent.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        taxonomy: []const u8,
        definition: operation.Json,
        drop_content: bool = false,
    };
    pub const Out = struct {
        id: []const u8,
        handle: []const u8,
        terms_rewritten: u32,
        values_dropped: u32,
    };
    pub const example: In = .{
        .taxonomy = "topics",
        .definition = .{
            .text = example_definition,
        },
    };
    pub const example_out: Out = .{
        .id = example_id,
        .handle = "topics",
        .terms_rewritten = 0,
        .values_dropped = 0,
    };
    pub const field_docs: operation.Docs(In) = .{
        .taxonomy = "Handle or id",
        .definition = "The complete new definition as JSON",
        .drop_content = "Delete the values of fields that the new definition removes",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .id = "The taxonomy's id",
        .handle = "Its handle",
        .terms_rewritten = "Terms whose values were converted or re-indexed",
        .values_dropped = "Values deleted for removed fields",
    };
};

pub const Get = struct {
    pub const name = "taxonomy.get";
    pub const description = "Read a taxonomy's full definition";
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        taxonomy: []const u8,
    };
    pub const Out = struct {
        id: []const u8,
        /// The full definition as JSON, as `taxonomy.create` takes it.
        definition: operation.Json,
        created_at: i64,
        updated_at: i64,
    };
    pub const example: In = .{
        .taxonomy = "topics",
    };
    pub const example_out: Out = .{
        .id = example_id,
        .definition = .{
            .text = example_definition,
        },
        .created_at = 1789650000000,
        .updated_at = 1789650000000,
    };
    pub const field_docs: operation.Docs(In) = .{
        .taxonomy = "Handle or id",
    };
};

pub const List = struct {
    pub const name = "taxonomy.list";
    pub const description = "List taxonomies";
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        limit: u32 = 50,
        offset: u32 = 0,
    };
    pub const Out = struct {
        taxonomies: []const Summary,
        total: u32 = 0,
    };
    pub const field_docs: operation.Docs(In) = .{
        .limit = "How many at most; 50 when omitted, up to 200",
        .offset = "How many to pass over first, by name: the next page's start",
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .taxonomies = &.{.{
            .id = example_id,
            .handle = "topics",
            .name = "Topics",
            .kind = .record,
            .public = true,
            .system = false,
            .owner = "",
            .editor = "form",
            .fields = 2,
        }},
    };
    pub const output_docs: operation.Docs(Out) = .{
        .taxonomies = "Sorted by name",
        .total = "How many the caller sees in all",
    };
};

pub const Delete = struct {
    pub const name = "taxonomy.delete";
    pub const description = "Delete a taxonomy; refuses while it has terms unless forced";
    pub const details =
        \\Admins only. With `force`, every term goes too, and with them every assignment
        \\of records to those terms; the records' `terms` fields keep pointing at ids
        \\that no longer exist until the records are saved again.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        taxonomy: []const u8,
        force: bool = false,
    };
    pub const Out = struct {
        deleted: bool,
        /// The handle it had.
        handle: []const u8,
        terms_removed: u32,
        /// Its trash entry: `trash restore --id` brings it back.
        trash: []const u8 = "",
    };
    pub const example: In = .{
        .taxonomy = "tags",
    };
    pub const example_out: Out = .{
        .deleted = true,
        .handle = "tags",
        .terms_removed = 0,
        .trash = "0190a1b2c3d40001a1b2c3d4",
    };
    pub const field_docs: operation.Docs(In) = .{
        .taxonomy = "Handle or id",
        .force = "Also delete every term of the taxonomy",
    };
};

pub const Validate = struct {
    pub const name = "taxonomy.validate";
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
            .text = "{\"handle\":\"topics\",\"name\":\"Topics\",\"kind\":\"settings\"," ++
                "\"fields\":[]}",
        },
    };
    pub const example_out: Out = .{
        .valid = false,
        .problems = &.{
            .{
                .path = "kind",
                .message = "a taxonomy holds terms: its kind is record",
            },
        },
    };
};
