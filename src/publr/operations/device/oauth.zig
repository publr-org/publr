//! A device that is an MCP client (a tool adding this Publr by its address): its sign-in is a
//! device request like any other, approved on the same page, but the client never holds a
//! device code. It is sent back with a code of its own once approved, and trades that code,
//! with the PKCE verifier only it has, for the device's token.
const operation = @import("../../operation.zig");
const device = @import("../device.zig");

pub const state_len_max: u32 = 512;
pub const example_client_id = "pc_Q3Vyc29yCmh0dHA6Ly9sb2NhbGhvc3Q6ODc4Ny9jYWxsYmFjaw";
pub const example_redirect = "http://localhost:8787/callback";
pub const example_challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM";
/// The code an approved client was sent back with, in `device exchange`'s example.
pub const example_code = "7e1a7e1a7e1a7e1a7e1a7e1a7e1a7e1a7e1a7e1a7e1a7e1a7e1a7e1a7e1a7e1a";

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
    pub const kind: operation.Kind = .write;
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
    pub const field_docs: operation.Docs(In) = .{
        .client_id = "The client's id, from `/oauth/register`",
        .redirect_uri = "Where to send the person back, one the client registered",
        .code_challenge = "The client's PKCE challenge, S256",
        .state = "The client's own value, sent back with the code, up to 512 characters",
        .scope = "The most it asks to do: `read`, `write`, `production` or `publish`",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .user_code = "The code the person approves",
        .approve_path = "Where the person approves it, on this site",
    };
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
    pub const kind: operation.Kind = .write;
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
    pub const field_docs: operation.Docs(In) = .{
        .code = "The code the client was sent back with",
        .code_verifier = "The PKCE verifier the challenge was made from",
        .client_id = "The client's id, as it asked",
        .redirect_uri = "Where it asked to be sent back",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .token = "`id.secret`, for `Authorization: Bearer`",
        .scope = "What the person let it do",
    };
};
