//! The shape of an operation's input or output, as data: a flat list of nodes, the root
//! first, each pointing at the node it sits in. A contract's parts carry their shapes so;
//! a value written as one JSON scalar names its kind (`pub const json_scalar: Kind`).
const compact_json = @import("../../model/compact_json.zig");

pub const Kind = enum { string, integer, number, boolean, enumeration, list, object, reference };

pub const Node = struct {
    /// The node it sits in; the root's is -1.
    parent: i32,
    /// Its field name inside an object; `[]` for a list's items; empty for the root.
    name: []const u8 = "",
    kind: Kind,
    /// Whether it may be null.
    optional: bool = false,
    /// Whether the object it sits in requires it: no default, not optional.
    required: bool = true,
    /// An enumeration's values.
    values: []const []const u8 = &.{},
    /// A reference's content type: the caller sends an id, the operation gets the record.
    to: []const u8 = "",

    pub const publr_form = .fields;

    /// Written without its defaults: a manifest holds thousands.
    pub fn jsonStringify(node: Node, writer: anytype) @TypeOf(writer.*).Error!void {
        return compact_json.write(node, writer);
    }
};
