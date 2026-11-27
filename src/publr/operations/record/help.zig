//! `record.help`: the help under each field of a record in the editor, applied as
//! `<type>.<field>.help` for plugins to modify from the document as it stands (saved or
//! not): help that follows the field's value, or other fields'. Nothing is stored; the
//! editor asks again as its values change.
const operation = @import("../../operation.zig");
const record = @import("../record.zig");

/// One field's help as the modifiers left it.
pub const Help = struct {
    field: []const u8,
    help: []const u8,
};

pub const Helps = struct {
    pub const name = "record.help";
    pub const description = "The help under each field, for a document as is";
    pub const details =
        \\Any signed-in account. The help of each top-level field of `type` that a
        \\plugin modifies, applied as `<type>.<field>.help` (`publr.modify("*.*.help",
        \\…)`): each takes the `field`, the whole `record` and the `help` so far, and
        \\answers the help to show. Modifiers read only. A field nobody modifies is left
        \\out: its help is the type's. The document is the editor's, saved or not.
    ;
    pub const kind: operation.Kind = .read;
    pub const open = true;
    pub const In = struct {
        type: []const u8,
        document: operation.Json,
    };
    pub const Out = struct {
        helps: []const Help,
    };
    pub const example_signed_in = true;
    pub const example: In = .{
        .type = "post",
        .document = .{
            .text = "{\"title\":\"Hello\"}",
        },
    };
    pub const example_out: Out = .{
        .helps = &.{},
    };
    pub const field_docs: operation.Docs(In) = .{
        .type = "The record's type",
        .document = "Its fields as JSON, as the editor holds them",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .helps = "Each modified field's `field` and the `help` to show",
    };
};
