//! `project.get`: anything the project stores read exactly as `project.put` takes it, with
//! its ids, and the ids of everything of a kind.
const operation = @import("../../operation.zig");
const operation_define = @import("../../plugin/operation_define.zig");

/// A record's id the examples name.
const example_draft_id = "c3d4e5f60718293a4b5c6d7e";

/// Units one call reads the rows of, at most.
pub const ids_max: u32 = 1024;
/// Ids one page of `every` lists, at most.
pub const listed_max: u32 = 10_000;

/// One thing the project stores, read: its id, its rows by table (`{}`: not there).
pub const Held = struct {
    id: []const u8,
    /// A content type's or taxonomy's handle; empty for anything else and when not there.
    handle: []const u8 = "",
    rows: operation.Json,
};

/// One thing of the kind, listed by `every`.
pub const Listed = struct {
    id: []const u8,
    /// A content type's or taxonomy's handle; empty for anything else.
    handle: []const u8 = "",
};

pub const Get = struct {
    pub const name = "project.get";
    pub const description = "Read anything the project stores exactly as project.put takes " ++
        "it, with its ids";
    pub const details =
        \\The read half of `project.put`, for plugins that keep copies of a project in sync
        \\(a rollback, a promotion, a merge): each unit of `kind` named in `ids` with its
        \\stored rows as JSON objects by column, by table, each table's rows ordered by
        \\their text, `{}` for one that is not there. Kinds and their tables are `put`'s;
        \\search text is made from the values, so it is never read. With `every`, also the
        \\ids of every unit of the kind, in order, a page at a time (`next` continues it),
        \\and a content type's or a taxonomy's handle beside its id. Changes nothing. Only
        \\plugins call it (administrators too); a plugin needs the `project.put`
        \\permission. Rows only: files are not read.
    ;
    pub const kind: operation.Kind = .read;
    pub const untrusted_callers = false;
    pub const answer: ?operation_define.Answer = .plugin_calls;
    pub const In = struct {
        kind: []const u8,
        ids: []const []const u8 = &.{},
        every: bool = false,
        after: []const u8 = "",

        pub const bulk_limits = .{
            .ids = ids_max,
        };
    };
    pub const Out = struct {
        units: []const Held = &.{},
        every: []const Listed = &.{},
        next: []const u8 = "",

        pub const bulk_limits = .{
            .units = ids_max,
            .every = listed_max,
        };
    };
    pub const example: In = .{
        .kind = "record",
        .ids = &.{example_draft_id},
    };
    pub const example_out: Out = .{
        .units = &.{.{
            .id = example_draft_id,
            .rows = .{
                .text = "{\"records\":[{\"id\":\"c3d4e5f60718293a4b5c6d7e\",\"status\":" ++
                    "\"published\"}],\"record_values\":[],\"record_terms\":[]}",
            },
        }},
    };
    pub const field_docs: operation.Docs(In) = .{
        .kind = "What is read: `record`, `term`, `internal`, `content_type`, `taxonomy`, " ++
            "`field_group`, `role`, `user` or `plugin`",
        .ids = "The units whose rows are read, by the id `project.put` knows them by",
        .every = "Also list the ids of every unit of the kind, a page at a time",
        .after = "With `every`, the page after this id: the `next` the last page answered",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .units = "Each unit of `ids`, in their order: its `id`, a content type's or " ++
            "taxonomy's `handle`, and its `rows` by table (`{}` when it is not there)",
        .every = "With `every`, each unit's `id` and a content type's or taxonomy's `handle`",
        .next = "The next page's `after`; empty after the last",
    };
};
