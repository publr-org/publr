//! A device collecting its token: asking whether its person decided (`poll`, a read, so
//! waiting writes nothing), then taking the token once (`claim`); or getting one at once
//! through the trusted issuer (`redeem`).

const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const model = @import("../../model/device.zig");
const sign_on = @import("../sign_on.zig");
const device = @import("../device.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const operations = [_]type{ Poll, Claim, Redeem };

/// The request a device code names, unless it lapsed: then null, as for an unknown code.
fn request_of(ctx: *Ctx, device_code: []const u8) Error!?store.device_requests.Request {
    std.debug.assert(ctx.now_ms >= 0);

    if (device_code.len != device.device_code_len) {
        return null;
    }

    const hash = device.hash_of(device_code);
    const found = try store.device_requests.find_by_code_hash(ctx.db, ctx.arena, hash);
    const request = found orelse return null;

    if (request.expires_at <= ctx.now_ms) {
        return null;
    }

    std.debug.assert(request.state.len > 0);

    return request;
}

pub const Poll = struct {
    pub const name = "device.poll";
    /// Never written to the logs.
    pub const secret = .{"device_code"};
    pub const description = "Whether a device's person decided yet";
    pub const details =
        \\Anyone holding the device code may call it. `state` is `pending` (ask again
        \\after `interval_s`), `approved` (take the token with `device claim`), `denied`, or
        \\`expired` (or unknown). It writes nothing, so asking often costs nothing.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const open = true;
    pub const In = struct { device_code: []const u8 };
    pub const Out = struct { state: []const u8 };
    pub const example: In = .{ .device_code = device.example_device_code };
    pub const example_out: Out = .{ .state = "pending" };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .device_code = "What `device start` answered",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .state = "`pending`, `approved`, `denied` or `expired`",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.now_ms >= 0);

        const request = try request_of(ctx, in.device_code) orelse return .{ .state = "expired" };
        const known = std.mem.eql(u8, request.state, "pending") or
            std.mem.eql(u8, request.state, "approved");

        return .{ .state = if (known) request.state else "denied" };
    }
};

pub const Claim = struct {
    pub const name = "device.claim";
    /// Never written to the logs.
    pub const secret = .{"device_code"};
    pub const description = "Take an approved device's token, once";
    pub const details =
        \\Anyone holding the device code may call it, once `device poll` says `approved`.
        \\The token is given once and the request used up; keep the token like a password.
        \\Not found while the request waits, or once it was denied, lapsed or claimed.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const open = true;
    pub const In = struct { device_code: []const u8 };
    pub const Out = struct { token: []const u8, user_id: []const u8, scope: []const u8 };
    pub const example: In = .{ .device_code = device.example_device_code };
    pub const example_out: Out = .{
        .token = "56a0794f6b1c67062563204a.ea477bba173fbbd2cd5fc9808892da24d65b38...",
        .user_id = "3f9c1e0a5b7d2c4e6f8a9b0c",
        .scope = "drafts",
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .device_code = "What `device start` answered",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .token = "`id.secret`, for `Authorization: Bearer`",
        .user_id = "The account it acts for",
        .scope = "What the person let it do",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const request = try request_of(ctx, in.device_code) orelse return error.NotFound;
        const user_id = request.user_id orelse return error.NotFound;

        if (!std.mem.eql(u8, request.state, "approved")) {
            return error.NotFound;
        }

        try store.device_requests.remove(ctx.db, device.hash_of(in.device_code));

        const created = try store.devices.create(ctx.db, ctx.io, ctx.arena, .{
            .user_id = user_id,
            .name = request.name,
            .scope = request.scope,
        }, ctx.now_ms);

        ctx.notice("auth.device_approved", created.device.id);

        return .{
            .token = try ctx.arena.dupe(u8, created.token_text()),
            .user_id = user_id,
            .scope = request.scope,
        };
    }
};

pub const Redeem = struct {
    pub const name = "device.redeem";
    /// Never written to the logs.
    pub const secret = .{"token"};
    pub const description = "Get a device's token with a sign-on token the trusted issuer signed";
    pub const details =
        \\Anyone may call it: the sign-on token is the credential, as for `sign_on redeem`,
        \\and is used up. The issuer (a Publr Cloud dashboard) has its person's approval
        \\already; the device it names acts for the account the token names, under `scope`.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const open = true;
    pub const In = struct { token: []const u8, name: []const u8, scope: []const u8 };
    pub const Out = struct { token: []const u8, user_id: []const u8, device_id: []const u8 };
    pub const example: In = .{
        .token = "eyJhdWQiOiJhMWIyYzNkNGU1ZjZhN2I4Ii4uLn0.c2lnbmF0dXJl...",
        .name = "A chat app",
        .scope = "drafts",
    };
    pub const example_out: Out = .{
        .token = "56a0794f6b1c67062563204a.ea477bba173fbbd2cd5fc9808892da24d65b38...",
        .user_id = "3f9c1e0a5b7d2c4e6f8a9b0c",
        .device_id = "56a0794f6b1c67062563204a",
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .token = "The sign-on token the issuer signed",
        .name = "What the device is called, 1 to 80 characters",
        .scope = "`read`, `drafts` or `write`",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .token = "The device's token, `id.secret`; treat it like a password",
        .user_id = "The account it acts for",
        .device_id = "The device, as `device list` shows it",
    };

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
        ctx.notice("auth.device_approved", created.device.id);

        return .{
            .token = try ctx.arena.dupe(u8, created.token_text()),
            .user_id = user.id,
            .device_id = created.device.id,
        };
    }
};
