//! Views of the content list: saved by name, and the default each type starts at.
const operation = @import("../operation.zig");

/// A type's default view: `view.default`, `view.save_default`, `view.reset_default`.
const default = @import("view/default.zig");
pub const Default = default.Default;
pub const SaveDefault = default.SaveDefault;
pub const ResetDefault = default.ResetDefault;
pub const Named = default.Named;
pub const Operator = default.Operator;
pub const Filterable = default.Filterable;

pub const namespace: operation.Namespace = .{
    .name = "view",
    .label = "Saved views",
    .area = .background,
    .summary = "Views of the content list: saved by name, and the default each type starts at",
    .details =
    \\A view is how the content list looks: which types, filter clauses, a search, an
    \\order, the columns shown, the page size, and the fields offered to filter and order
    \\by. It travels as JSON: one clause per filter (`{"key":"status","operator":"is",
    \\"value":"draft"}`, `{"key":"field.total","operator":"more","value":"4999"}`, as
    \\`record list --filters` takes them), `order` as `title` or `-updated` (descending)
    \\or a field (`-total`). `me` and durations are resolved when the list is drawn, so a
    \\saved view stays current.
    \\
    \\Saved views are a person's own, or made for everyone by an administrator
    \\(`for_everyone`): listed for all, copied by anyone, changed by administrators. A
    \\type's default view starts from its plugin's (`.data_view`), then the one
    \\administrators saved for everyone, then the person's own (`view default`,
    \\`view save-default`, `view reset-default`). Signed-in callers only.
    ,
};

/// One saved view, as every operation answers it.
pub const Saved = struct {
    id: []const u8,
    name: []const u8,
    query: operation.Json,
    created_at: i64,
    updated_at: i64,
    /// Made by an administrator for everyone.
    shared: bool = false,
};

pub const example_id = "5e6f7a8b9c0d1e2f3a4b5c6d";
const example_query = "{\"clauses\":[" ++
    "{\"key\":\"status\",\"operator\":\"is\",\"value\":\"draft\"}," ++
    "{\"key\":\"created\",\"operator\":\"by\",\"value\":\"me\"}]}";
const example_saved: Saved = .{
    .id = example_id,
    .name = "My drafts",
    .query = .{
        .text = example_query,
    },
    .created_at = 1789650000000,
    .updated_at = 1789653600000,
};

pub const List = struct {
    pub const name = "view.list";
    pub const description = "List the caller's saved views and those made for everyone";
    pub const details =
        \\The caller's own views by name, then the ones made for everyone (`shared`).
        \\`query` holds the view as the content list takes it.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        views: []const Saved,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .views = &.{example_saved},
    };
};

pub const Get = struct {
    pub const name = "view.get";
    pub const description = "Read one saved view";
    pub const details =
        \\Not found unless the view is the caller's own or made for everyone.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        id: []const u8,
    };
    pub const Out = struct {
        view: Saved,
    };
    pub const example: In = .{
        .id = example_id,
    };
    pub const example_out: Out = .{
        .view = example_saved,
    };
    pub const field_docs: operation.Docs(In) = .{
        .id = "The view's id",
    };
};

pub const Create = struct {
    pub const name = "view.create";
    pub const description = "Save the content list as a view of the caller's own, or everyone's";
    pub const details =
        \\`name` is up to 80 characters; `query` is the view as JSON, every key optional:
        \\`types` (handles), `type_view` (one type's own view), `clauses` (each a `key`,
        \\an `operator` and a `value` of a filter the registry knows: `status is draft`,
        \\`created by me`, `updated within 7d`, `created before 2026-01-01`; or on a field,
        \\`field.total more 4999`), `search`, `order` (`title`, `-updated`, `-total`),
        \\`columns`, `per_page` (10, 20, 50, 100), `filterable`, `orderable`. Up to 64 views
        \\per user. `for_everyone` makes it everyone's (up to 64): administrators only.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        name: []const u8,
        query: operation.Json = .object,
        for_everyone: bool = false,
    };
    pub const Out = Saved;
    pub const example: In = .{
        .name = "My drafts",
        .query = .{
            .text = example_query,
        },
    };
    pub const example_out: Out = example_saved;
    pub const field_docs: operation.Docs(In) = .{
        .name = "The view's name, as the sidebar shows it",
        .query = "The view, as JSON",
        .for_everyone = "Made for everyone (administrators only)",
    };
};

pub const Update = struct {
    pub const name = "view.update";
    pub const description = "Rename a saved view, or give it a new view, or both";
    pub const details =
        \\Fields left out keep their value. The caller's own views, and (administrators)
        \\the ones made for everyone.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        name: ?[]const u8 = null,
        query: ?operation.Json = null,
    };
    pub const Out = Saved;
    pub const example: In = .{
        .id = example_id,
        .name = "My drafts",
    };
    pub const example_out: Out = example_saved;
    pub const field_docs: operation.Docs(In) = .{
        .id = "The view's id",
        .name = "A new name",
        .query = "New filters, as JSON",
    };
};

pub const Delete = struct {
    pub const name = "view.delete";
    pub const description = "Delete a saved view";
    pub const details =
        \\The caller's own views, and (administrators) the ones made for everyone. Nothing
        \\else is touched: a view is only a way of looking at the content.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
    };
    pub const Out = struct {
        deleted: bool,
    };
    pub const example: In = .{
        .id = example_id,
    };
    pub const example_out: Out = .{
        .deleted = true,
    };
    pub const field_docs: operation.Docs(In) = .{
        .id = "The view's id",
    };
};
