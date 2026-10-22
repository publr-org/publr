//! A transition someone asked for on a record, declined or withdrawn.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const record_operations = @import("../record.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

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
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
    };
    pub const Out = struct {
        declined: []const u8,
    };
    pub const example: In = .{
        .id = record_operations.example_draft_id,
    };
    pub const example_out: Out = .{
        .declined = "publish",
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The record id",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .declined = "The transition that was waiting",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);
        std.debug.assert(granted.allows());

        if (in.id.len == 0 or in.id.len > 128) {
            return error.Invalid;
        }

        const domain = record_operations.domain;
        const row = try domain.access.load(ctx, in.id, granted) orelse return error.NotFound;

        try domain.lifecycle.requests.decline(ctx, row);

        return .{
            .declined = row.requested,
        };
    }
};
