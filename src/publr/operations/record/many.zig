//! Many records moved at once: the ones named, or every one a list's conditions keep.
const operation = @import("../../operation.zig");
const record = @import("../record.zig");

pub const TransitionMany = struct {
    pub const name = "record.transition_many";
    pub const description = "Move many records by one transition: the ones named, or " ++
        "every record a list's filters keep";
    pub const details =
        \\Either name the records (`ids`) or set `matching` with the conditions `record
        \\list` takes (`type`, `types`, `filters`, `search`): every record they keep moves,
        \\in one call, whatever their number. The transition is named, as `record
        \\transition` takes it, and leads to one status in every type it reaches; records
        \\already there are left out. Each is checked as `record transition` checks it, and
        \\one that may not move is reported in `failed` (the first 100 by name, all in
        \\`not_moved`) while the rest go on. Pending edits of records going live are applied,
        \\as `record publish` does.
        \\Hooks on `record transition` run for each record; event hooks hear each record's
        \\events as if it had moved on its own. `restore` and `destroy` run `record
        \\transition` on each record in the trash, one at a time, so each goes back to the
        \\status it had, as on its own; the others are not moved.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        transition: []const u8,
        ids: []const []const u8 = &.{},
        matching: bool = false,
        type: ?[]const u8 = null,
        types: []const []const u8 = &.{},
        filters: []const []const u8 = &.{},
        search: ?[]const u8 = null,
    };
    pub const Failed = @import("../../model/record.zig").Failed;
    pub const Out = struct {
        moved: u32,
        not_moved: u32,
        failed: []const Failed,
    };
    pub const example: In = .{
        .transition = "archive",
        .matching = true,
        .type = "post",
        .filters = &.{"updated:before:2025-01-01"},
    };
    pub const example_out: Out = .{
        .moved = 1768,
        .not_moved = 0,
        .failed = &.{},
    };
    pub const field_docs: operation.Docs(In) = .{
        .transition = "The transition's name, `archive`",
        .ids = "The records to move, by id",
        .matching = "Move every record the conditions keep instead of named ones",
        .type = "With `matching`: one content type, by handle or id",
        .types = "With `matching`: several content types; neither: every regular type",
        .filters = "With `matching`: clauses as `record list` takes them",
        .search = "With `matching`: full-text query over searchable fields",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .moved = "How many records moved",
        .not_moved = "How many could not move",
        .failed = "The first 100 that could not move, and why",
    };
};
