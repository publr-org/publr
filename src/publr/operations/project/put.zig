//! `project.put`: anything the project stores put exactly as another copy of it keeps it,
//! with its ids.
const operation = @import("../../operation.zig");
const operation_define = @import("../../plugin/operation_define.zig");

/// A record's id the examples name.
const example_draft_id = "c3d4e5f60718293a4b5c6d7e";

/// Units one call puts, at most.
pub const units_max: u32 = 10_000;

/// One thing the project stores: its kind, its id, its rows by table (`{}`: not there).
pub const Unit = struct {
    kind: []const u8,
    id: []const u8,
    rows: operation.Json,
};

/// A unit put, and what became of it: `added`, `replaced`, `removed` or `unchanged`.
pub const Done = struct {
    kind: []const u8,
    id: []const u8,
    outcome: []const u8,
    /// A content type's or taxonomy's handle; empty for anything else.
    handle: []const u8 = "",
};

pub const Put = struct {
    pub const name = "project.put";
    pub const description = "Put anything the project stores exactly as another copy of it " ++
        "keeps it, with its ids";
    pub const details =
        \\For plugins that keep copies of a project in sync (a rollback, a promotion, a
        \\merge): each unit's stored rows as JSON objects by column, by table, `{}` to
        \\remove it. Kinds and their tables: `record` (`records`, `record_values`,
        \\`record_terms`), `term` (`terms`, `term_values`), `internal` (`internal_records`,
        \\`internal_record_values`), `content_type` and `taxonomy` (its row and its
        \\`field_groups` row), `field_group` (a custom field group, by its handle), `role`
        \\(`roles`, `role_grants`), `user` (`users`, `user_roles`, `user_types`,
        \\`user_values`, `user_search`, `identities`) and `plugin` (an installed plugin's
        \\`sandboxed_plugins` row: its versions and grants, never its files). Ids, versions
        \\and timestamps are kept as given; a BLOB is hex; search text of records and terms
        \\is made again. A unit already as given is not written. Records and terms then land
        \\as a person making the same change would: slugs and unique values free,
        \\references live, the replaced live document kept as a revision, the change's
        \\events raised. A refused check fails the whole call. Only plugins call it
        \\(administrators too); a plugin needs the `project.put` permission. Rows only:
        \\files (plugins' modules, apps, `publr.zon`) are not put.
    ;
    pub const kind: operation.Kind = .write;
    pub const untrusted_callers = false;
    pub const answer: ?operation_define.Answer = .plugin_calls;
    pub const In = struct {
        units: []const Unit = &.{},

        pub const bulk_limits = .{
            .units = units_max,
        };
    };
    pub const Out = struct {
        put: []const Done,

        pub const bulk_limits = .{
            .put = units_max,
        };
    };
    pub const example: In = .{
        .units = &.{.{
            .kind = "record",
            .id = example_draft_id,
            .rows = .{
                .text = "{\"records\":[{\"id\":\"c3d4e5f60718293a4b5c6d7e\",\"status\":" ++
                    "\"published\"}],\"record_values\":[]}",
            },
        }},
    };
    pub const example_out: Out = .{
        .put = &.{.{
            .kind = "record",
            .id = example_draft_id,
            .outcome = "replaced",
        }},
    };
    pub const field_docs: operation.Docs(In) = .{
        .units = "Each `kind`, `id` and `rows` (its rows by table; `{}` removes it)",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .put = "Each unit's `kind`, `id`, `outcome` (added, replaced, removed or " ++
            "unchanged) and, for a content type or taxonomy, its `handle`",
    };
};
