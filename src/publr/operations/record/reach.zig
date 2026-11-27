//! What an app reaches: the types living in it or shared with it, and of a plugin's only
//! those of the plugins it lists; and why a record is out of a reader's reach.
const operation = @import("../../operation.zig");
const record = @import("../record.zig");

pub const Reason = enum { access, not_shared, deleted };

pub const Reach = struct {
    pub const name = "record.reach";
    pub const description = "Say why a record is out of the caller's reach, or that it is not";
    pub const details =
        \\What a page shows in place of a reference it may not follow. `reason` is
        \\`access` (the caller may not read it: a Private type, or one its roles do not
        \\reach), `not_shared` (its type is not shared with the app the call is for) or
        \\`deleted` (in the trash, or gone for good); null when the caller reads it, or
        \\when it is not published yet for a caller who reads live records only. `type`
        \\is its type's handle, empty when the record is gone. Nothing else of the record
        \\is said. Anyone may ask.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        id: []const u8,
    };
    pub const Out = struct {
        reason: ?Reason,
        type: []const u8,
        /// It is a plugin's internal record: there, its type said, read through `internal.*`.
        internal: bool = false,
    };
    pub const example: In = .{
        .id = "a1b2c3d4e5f60718293a4b5c",
    };
    pub const example_out: Out = .{
        .reason = null,
        .type = "post",
    };
    pub const field_docs: operation.Docs(In) = .{
        .id = "The record id a reference holds",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .reason = "`access`, `not_shared` or `deleted`; null when nothing stands in the way",
        .type = "The record's type, by handle; empty when it is gone",
        .internal = "A plugin's internal record, read through `internal.*`",
    };
};
