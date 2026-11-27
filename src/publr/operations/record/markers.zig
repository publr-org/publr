//! `record.markers`: the markers beside each field's label in the editor, worked out from the
//! document as it stands (saved or not), applied as `<type>.markers` for plugins to modify:
//! the languages plugin says a field is translated, an A/B test that it varies. Nothing is
//! stored; the editor asks again as its values change.
const operation = @import("../../operation.zig");
const record = @import("../record.zig");

/// One marker beside one field's label.
pub const Marker = struct {
    field: []const u8,
    label: []const u8,
    /// What the markers of its dimension are of, drawn once before them: `Hero test`.
    group: []const u8 = "",
    /// `outline` (the default), `neutral`, `success` or `danger`.
    tone: []const u8 = "outline",
    /// What clicking it shows: the field in this dimension (empty: no link) at `code`.
    dimension: []const u8 = "",
    code: []const u8 = "",
    /// `show`, or `hide` while the editor shows the field at this code.
    current: []const u8 = "show",
    /// A page of the admin it opens instead (`/admin/plugin/ab_test/attach?…`); empty: none.
    href: []const u8 = "",
};

pub const Markers = struct {
    pub const name = "record.markers";
    pub const description = "The markers beside each field's label, for a document as is";
    pub const details =
        \\Any signed-in account. One item per field of `type`, applied as `<type>.markers`
        \\for plugins to modify (`publr.modify("*.markers", …)`): each item has the
        \\`field`, the dimensions it `varies_by`, the whole `record` and the `markers` so
        \\far, and a modifier adds its own (`Translated`, `Varies in B`). Modifiers read
        \\only. The document is the editor's, saved or not; nothing is stored.
    ;
    pub const kind: operation.Kind = .read;
    pub const open = true;
    pub const In = struct {
        type: []const u8,
        document: operation.Json,
        /// The record, saved: what it holds back is never required.
        id: []const u8 = "",
    };
    pub const Out = struct {
        markers: []const Marker,
    };
    pub const example_signed_in = true;
    pub const example: In = .{
        .type = "post",
        .document = .{
            .text = "{\"title\":\"Hello\"}",
        },
    };
    pub const example_out: Out = .{
        .markers = &.{},
    };
    pub const field_docs: operation.Docs(In) = .{
        .type = "The record's type",
        .document = "Its fields as JSON, as the editor holds them",
        .id = "The record's id once saved: a combination it holds back is never required",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .markers = "Each marker: the `field`, its `label` and `tone`",
    };
};
