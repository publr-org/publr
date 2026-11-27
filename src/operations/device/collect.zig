//! A device collecting its token: asking whether its person decided (`poll`, a read, so
//! waiting writes nothing), then taking the token once (`claim`); or getting one at once
//! through the trusted issuer (`redeem`).

const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const model = @import("../../model/device.zig");
const sign_on = @import("../sign_on.zig");
const device = @import("../device.zig");
const public = @import("../../publr/operations/device/collect.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const operations = [_]type{ Poll, Claim, Redeem };

/// The request a device code names, unless it lapsed: then null, as for an unknown code.
fn request_of(ctx: *Ctx, device_code: []const u8) Error!?store.device_requests.Request {
    std.debug.assert(ctx.now_ms >= 0);

    const offered = model.valid_offer_code(device_code);

    if (device_code.len != device.device_code_len and !offered) {
        return null;
    }

    const hash = device.hash_of(device_code);
    const found = try store.device_requests.find_by_code_hash(ctx.db, ctx.arena, hash);
    const request = found orelse return null;

    // An MCP client's request is collected only with its verifier (`device exchange`).
    if (request.expires_at <= ctx.now_ms or request.client_id.len > 0) {
        return null;
    }

    std.debug.assert(request.state.len > 0);

    return request;
}

pub const Poll = struct {
    pub const shape = public.Poll;
    pub const name = shape.name;
    pub const secret = shape.secret;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const open = shape.open;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.now_ms >= 0);

        const request = try request_of(ctx, in.device_code) orelse return .{
            .state = "expired",
        };
        const known = std.mem.eql(u8, request.state, "pending") or
            std.mem.eql(u8, request.state, "approved");

        return .{
            .state = if (known) request.state else "denied",
        };
    }
};

pub const Claim = struct {
    pub const shape = public.Claim;
    pub const name = shape.name;
    pub const secret = shape.secret;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const open = shape.open;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const request = try request_of(ctx, in.device_code) orelse return error.NotFound;
        const user_id = request.user_id orelse return error.NotFound;

        if (!std.mem.eql(u8, request.state, "approved")) {
            return error.NotFound;
        }

        try store.device_requests.remove(ctx.db, device.hash_of(in.device_code));

        const named = in.name orelse request.name;

        if (!model.valid_name(named)) {
            return error.Invalid;
        }

        const created = try store.devices.create(ctx.db, ctx.io, ctx.arena, .{
            .user_id = user_id,
            .name = named,
            .scope = request.scope,
        }, ctx.now_ms);

        return .{
            .token = try ctx.arena.dupe(u8, created.token_text()),
            .user_id = user_id,
            .scope = request.scope,
        };
    }
};

pub const Redeem = struct {
    pub const shape = public.Redeem;
    pub const name = shape.name;
    pub const secret = shape.secret;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const open = shape.open;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (!model.valid_name(in.name) or model.Scope.parse(in.scope) == null) {
            return error.Invalid;
        }

        const user = try sign_on.vouched_user(ctx, in.token);
        const created = try store.devices.create(ctx.db, ctx.io, ctx.arena, .{
            .user_id = user.id,
            .name = in.name,
            .scope = in.scope,
        }, ctx.now_ms);

        std.debug.assert(created.device.user_id.len > 0);

        return .{
            .token = try ctx.arena.dupe(u8, created.token_text()),
            .user_id = user.id,
            .device_id = created.device.id,
        };
    }
};
