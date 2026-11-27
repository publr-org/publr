//! A transition someone asked for on a record, declined or withdrawn.
const operation = @import("../../operation.zig");
const record = @import("../record.zig");

pub const DeclineRequest = struct {
    pub const name = "record.decline_request";
    pub const description = "Drop the transition someone asked for on a record";
    pub const details =
        \\Someone who may not publish asks instead (`record transition` answers `pending`):
        \\the transition waits on the record, `requested` and `requested_by` in `record get`,
        \\until someone who may runs it with `record transition` or declines it here. The
        \\asker may withdraw their own; anyone else must be allowed to publish. Not found
        \\when nothing waits.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
    };
    pub const Out = struct {
        declined: []const u8,
    };
    pub const example: In = .{
        .id = record.example_draft_id,
    };
    pub const example_out: Out = .{
        .declined = "publish",
    };
    pub const field_docs: operation.Docs(In) = .{
        .id = "The record id",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .declined = "The transition that was waiting",
    };
};
