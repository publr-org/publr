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

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const operations = [_]type{ Authorize, Exchange };

pub const state_len_max: u32 = 512;
pub const example_client_id = "pc_Q3Vyc29yCmh0dHA6Ly9sb2NhbGhvc3Q6ODc4Ny9jYWxsYmFjaw";
pub const example_redirect = "http://localhost:8787/callback";
pub const example_challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM";
/// The code an approved client was sent back with, in `device exchange`'s example.
pub const example_code = "7e1a" ** 16;

pub const Authorize = struct {
    pub const name = "device.authorize";
    pub const description = "Ask, as an MCP client, to act for an account: answers the code " ++
        "its person approves";
    pub const details =
        \\Anyone may call it; `/oauth/authorize` does, and sends the person's browser to the
        \\approve page. `client_id` is what `/oauth/register` answered, `redirect_uri` one of
        \\the addresses registered with it, `code_challenge` the client's PKCE challenge
        \\(S256). Once approved, the browser goes back to `redirect_uri` with a code the
        \\client trades for its token (`device exchange`). Lapses after ten minutes.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const open = true;
    pub const In = struct {
        client_id: []const u8,
        redirect_uri: []const u8,
        code_challenge: []const u8,
        state: []const u8 = "",
        scope: []const u8 = "publish",
    };
    pub const Out = struct {
        user_code: []const u8,
        approve_path: []const u8,
    };
    pub const example: In = .{
        .client_id = example_client_id,
        .redirect_uri = example_redirect,
        .code_challenge = example_challenge,
        .state = "xyz",
    };
    pub const example_out: Out = .{
        .user_code = "WXZB-CDFG",
        .approve_path = device.approve_path ++ "?code=WXZB-CDFG",
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .client_id = "The client's id, from `/oauth/register`",
        .redirect_uri = "Where to send the person back, one the client registered",
        .code_challenge = "The client's PKCE challenge, S256",
        .state = "The client's own value, sent back with the code, up to 512 characters",
        .scope = "The most it asks to do: `read`, `write`, `production` or `publish`",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .user_code = "The code the person approves",
        .approve_path = "Where the person approves it, on this site",
    };

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
    pub const name = "device.exchange";
    /// Never written to the logs.
    pub const secret = .{ "code", "code_verifier" };
    pub const description = "Trade an MCP client's code and verifier for its device's token";
    pub const details =
        \\Anyone may call it; `/oauth/token` does. The code is the one the client was sent
        \\back with, used once; the verifier must be the one its challenge was made from,
        \\and `client_id` and `redirect_uri` the ones it asked with. Not found otherwise.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const open = true;
    pub const In = struct {
        code: []const u8,
        code_verifier: []const u8,
        client_id: []const u8,
        redirect_uri: []const u8,
    };
    pub const Out = struct {
        token: []const u8,
        scope: []const u8,
    };
    pub const example: In = .{
        .code = example_code,
        .code_verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
        .client_id = example_client_id,
        .redirect_uri = example_redirect,
    };
    pub const example_out: Out = .{
        .token = "56a0794f6b1c67062563204a.ea477bba173fbbd2cd5fc9808892da24d65b38...",
        .scope = "production",
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .code = "The code the client was sent back with",
        .code_verifier = "The PKCE verifier the challenge was made from",
        .client_id = "The client's id, as it asked",
        .redirect_uri = "Where it asked to be sent back",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .token = "`id.secret`, for `Authorization: Bearer`",
        .scope = "What the person let it do",
    };

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
