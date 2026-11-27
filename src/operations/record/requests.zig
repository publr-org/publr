//! A transition someone asked for on a record, declined or withdrawn.

const std = @import("std");
const public = @import("../../publr/operations/record/requests.zig");
const sdk = @import("../../sdk.zig");
const record_operations = @import("../record.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const DeclineRequest = struct {
    pub const shape = public.DeclineRequest;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

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
