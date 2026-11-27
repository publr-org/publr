//! A device that is an MCP client (a tool adding this Publr by its address): its sign-in is a
//! device request like any other, approved on the same page, but the client never holds a
//! device code. It is sent back with a code of its own once approved, and trades that code,
//! with the PKCE verifier only it has, for the device's token.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const model = @import("../../model/device.zig");
const oauth = @import("../../model/oauth.zig");
const device = @import("../device.zig");
const public = @import("../../publr/operations/device/oauth.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const operations = [_]type{ Authorize, Exchange };

pub const state_len_max = public.state_len_max;
pub const example_client_id = public.example_client_id;
pub const example_redirect = public.example_redirect;
pub const example_challenge = public.example_challenge;
/// The code an approved client was sent back with, in `device exchange`'s example.
pub const example_code = public.example_code;

pub const Authorize = struct {
    pub const shape = public.Authorize;
    pub const name = shape.name;
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

        const client = try oauth.client_of(ctx.arena, in.client_id) orelse return error.NotFound;
        const fits = oauth.registered(client, in.redirect_uri) and
            oauth.valid_challenge(in.code_challenge) and
            in.state.len <= state_len_max and model.Scope.parse(in.scope) != null;

        if (!fits) {
            return error.Invalid;
        }

        _ = try store.device_requests.cleanup(ctx.db, ctx.now_ms);

        // Never given out: the client is sent back with a code made once it is approved.
        var unused: [32]u8 = undefined;
        ctx.io.random(&unused);

        const user_code = try device.insert(ctx, .{
            .code_hash = unused,
            .name = client.name,
            .scope = in.scope,
            .expires_at = ctx.now_ms + model.request_lifetime_ms,
            .client_id = in.client_id,
            .redirect_uri = in.redirect_uri,
            .code_challenge = in.code_challenge,
            .client_state = in.state,
        });
        const path = std.fmt.allocPrint(ctx.arena, "{s}?code={s}", .{
            device.approve_path,
            user_code,
        });

        return .{
            .user_code = user_code,
            .approve_path = path catch return error.OutOfMemory,
        };
    }
};

pub const Exchange = struct {
    pub const shape = public.Exchange;
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

        if (in.code.len != device.device_code_len) {
            return error.NotFound;
        }

        const hash = device.hash_of(in.code);
        const found = try store.device_requests.find_by_code_hash(ctx.db, ctx.arena, hash);
        const request = found orelse return error.NotFound;
        const user_id = request.user_id orelse return error.NotFound;
        const matches = request.expires_at > ctx.now_ms and
            std.mem.eql(u8, request.state, "approved") and request.client_id.len > 0 and
            std.mem.eql(u8, request.client_id, in.client_id) and
            std.mem.eql(u8, request.redirect_uri, in.redirect_uri) and
            oauth.verifies(in.code_verifier, request.code_challenge);

        if (!matches) {
            return error.NotFound;
        }

        try store.device_requests.remove(ctx.db, hash);

        const created = try store.devices.create(ctx.db, ctx.io, ctx.arena, .{
            .user_id = user_id,
            .name = request.name,
            .scope = request.scope,
        }, ctx.now_ms);

        return .{
            .token = try ctx.arena.dupe(u8, created.token_text()),
            .scope = request.scope,
        };
    }
};

/// Where an MCP client's person goes once they decided: its return address with the code
/// (approved, under a fresh code only the client gets) or `error=access_denied`; empty for a
/// device's own request, whose device learns it by polling.
pub fn sent_back(
    ctx: *Ctx,
    request: store.device_requests.Request,
    approved: bool,
) Error![]const u8 {
    std.debug.assert(request.user_code.len > 0);

    if (request.client_id.len == 0) {
        return "";
    }

    std.debug.assert(request.redirect_uri.len > 0);

    var pair: []const u8 = "error=access_denied";

    if (approved) {
        var secret: [device.device_code_bytes]u8 = undefined;
        ctx.io.random(&secret);

        const code = std.fmt.bytesToHex(secret, .lower);

        if (!try store.device_requests.rekey(ctx.db, request.user_code, device.hash_of(&code))) {
            return error.NotFound;
        }

        pair = try print(ctx, "code={s}", .{&code});
    }

    var state: std.Io.Writer.Allocating = .init(ctx.arena);

    std.Uri.Component.percentEncode(&state.writer, request.client_state, unreserved) catch {
        return error.OutOfMemory;
    };

    const joiner: []const u8 = if (std.mem.indexOfScalar(u8, request.redirect_uri, '?') == null)
        "?"
    else
        "&";
    const with_state = if (request.client_state.len > 0)
        try print(ctx, "&state={s}", .{state.written()})
    else
        "";

    return print(ctx, "{s}{s}{s}{s}", .{ request.redirect_uri, joiner, pair, with_state });
}

fn unreserved(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '-' or char == '.' or char == '_' or
        char == '~';
}

fn print(ctx: *Ctx, comptime format: []const u8, args: anytype) Error![]const u8 {
    return std.fmt.allocPrint(ctx.arena, format, args) catch error.OutOfMemory;
}
