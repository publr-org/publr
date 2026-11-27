//! `record.shown`: records' titles as people see them, applied as `<type>.title` for plugins
//! to modify (`sdk/mods.zig`). What is stored and what `record.list` answers stay as they are.
const operation = @import("../../operation.zig");
const record = @import("../record.zig");

pub const Purpose = record.Purpose;

pub const Title = struct {
    id: []const u8,
    title: []const u8,
};

pub const Shown = struct {
    pub const name = "record.shown";
    pub const description = "The titles of records as people see them, modifiers applied";
    pub const details =
        \\Each record's title (its id when it has none), applied as `<type>.title` for
        \\plugins to modify (`publr.modify("variant.title", …)`): what the admin's lists,
        \\picker and reference cards show. Modifiers run once per type, read what their
        \\plugins are granted and never write; what they answer is text. Records the
        \\caller may not read are left out. Give `ids`, or a `type` for its newest.
        \\Stored values and `record list` are never changed.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        ids: []const []const u8 = &.{},
        type: ?[]const u8 = null,
        limit: u32 = 50,
        /// `edit`: from the pending copy of a record with changes, as its editor sees it.
        purpose: Purpose = .delivery,
    };
    pub const Out = struct {
        titles: []const Title,
    };
    pub const example: In = .{
        .ids = &.{record.example_id},
    };
    pub const example_out: Out = .{
        .titles = &.{
            .{
                .id = record.example_id,
                .title = "Hello, world",
            },
        },
    };
    pub const field_docs: operation.Docs(In) = .{
        .ids = "These records, up to 200",
        .type = "Or a type's records, newest first",
        .limit = "With `type`: how many, up to 200",
        .purpose = "`delivery` (default) or `edit`: pending copies where there are changes",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .titles = "Each readable record's id and the title shown for it",
    };
};
