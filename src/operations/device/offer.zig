//! A sign-in offered to a person's own computer: approved as it is made, by the person signed
//! in to the admin, and collected once with `device claim` by whoever holds its code within
//! ten minutes. What the Overview's agent command carries, so setting up a computer is one
//! command with nothing to approve.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const model = @import("../../model/device.zig");
const device = @import("../device.zig");
const public = @import("../../publr/operations/device/offer.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

/// What the device is called until its CLI names it.
pub const offered_name = "A computer set up from the Overview";

pub const Offer = struct {
    pub const shape = public.Offer;
    pub const example_signed_in = shape.example_signed_in;
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

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const user_id = switch (ctx.caller) {
            .user => |user| user.id,
            else => return error.Denied,
        };

        if (model.Scope.parse(in.scope) == null) {
            return error.Invalid;
        }

        _ = try store.device_requests.cleanup(ctx.db, ctx.now_ms);

        var random: [model.offer_code_len]u8 = undefined;
        ctx.io.random(&random);

        const code = model.offer_code(random);
        const expires_at = ctx.now_ms + model.request_lifetime_ms;
        const user_code = try device.insert(ctx, .{
            .code_hash = device.hash_of(&code),
            .name = offered_name,
            .scope = in.scope,
            .expires_at = expires_at,
        });
        const decided = try store.device_requests.decide(ctx.db, .{
            .state = "approved",
            .scope = in.scope,
            .user_id = user_id,
            .user_code = user_code,
        }, ctx.now_ms);

        std.debug.assert(decided);

        return .{
            .code = try ctx.arena.dupe(u8, &code),
            .expires_at = expires_at,
        };
    }
};
