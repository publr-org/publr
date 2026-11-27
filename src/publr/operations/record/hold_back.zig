//! What of a record goes live: the combinations of the site's dimensions it holds back.
const operation = @import("../../operation.zig");
const record = @import("../record.zig");

pub const HoldBack = struct {
    pub const name = "record.hold_back";
    pub const description = "Choose which combinations of a record's dimensions go live";
    pub const details =
        \\Every combination of the site's dimensions a record has (Polish, Polish in
        \\variation B) goes live with it, but the ones it holds back, listed here in place of
        \\the ones before; none puts every one live, and one the site adds later goes live.
        \\Each is a combination of the site's values as a field's key names it: `language=pl`,
        \\`language=pl,variation=b`. Held back where the dimension has pages of its own, the
        \\record is not at that address (not listed, not found); held back where a visitor is
        \\given a value, they read it as if the other dimensions were at their main values. A
        \\value a field must hold is never required where it is held back. A live record's
        \\choice waits with its pending changes (`changed`, `pending_held_back` in
        \\`record get`) until `record publish`, which checks it, or `record discard_changes`;
        \\any other record's takes effect at once (`held_back`, `;` between).
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        combinations: []const []const u8 = &.{},
    };
    pub const Out = struct {
        held_back: []const u8,
        changed: bool,
    };
    pub const example: In = .{
        .id = record.example_draft_id,
        .combinations = &.{"language=pl"},
    };
    pub const example_out: Out = .{
        .held_back = "language=pl",
        .changed = false,
    };
    pub const field_docs: operation.Docs(In) = .{
        .id = "The record id",
        .combinations = "Each combination held back (`language=pl`); none to put every one live",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .held_back = "What the record holds back once its changes are published, `;` between",
        .changed = "Whether it waits as pending changes: a live record's, until `record publish`",
    };
};
