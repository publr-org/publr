//! Signing in through someone the site trusts: an issuer (a Publr Cloud dashboard) signs a
//! short-lived token for one account on one site, and the site, holding only the issuer's
//! public key, turns it into an ordinary session. Nothing here needs the issuer to be up
//! once the token exists, and nothing shared is secret.
const operation = @import("../operation.zig");

pub const namespace: operation.Namespace = .{
    .name = "sign_on",
    .label = "Trusted sign-in",
    .area = .people,
    .summary = "Signing in through a trusted issuer, such as a Publr Cloud dashboard",
    .details =
    \\An administrator names the issuer once (`sign_on configure`): its address, its
    \\public key and this site's id in its eyes. From then on a token the issuer signed for
    \\an account of this site (`sign_on redeem`) signs that account in, like a password
    \\would: over HTTP at `/auth/sign-on`, and the admin's login page sends you to the
    \\issuer first.
    ,
};

pub const Configure = struct {
    pub const name = "sign_on.configure";
    /// Never written to the logs.
    pub const secret = .{"public_key"};
    pub const description = "Trust an issuer to sign people in to this site";
    pub const details =
        \\Administrators only. `issuer` is the issuer's address (`https://publr.app`),
        \\`public_key` its Ed25519 public key as 64 hex characters, `audience` this site's
        \\id in its tokens. Configuring again replaces the issuer.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        issuer: []const u8,
        public_key: []const u8,
        audience: []const u8,
    };
    pub const Out = struct {
        configured: bool,
    };
    pub const example: In = .{
        .issuer = "https://publr.app",
        .public_key = "d04ab232742bb4ab3a1368bd4615e4e6d0224ab71a016baf8520a332c9778737",
        .audience = "a1b2c3d4e5f6a7b8",
    };
    pub const example_out: Out = .{
        .configured = true,
    };
    pub const field_docs: operation.Docs(In) = .{
        .issuer = "The issuer's address, http(s)://host[:port], no path",
        .public_key = "Its Ed25519 public key, 64 hex characters",
        .audience = "This site's id in its tokens",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .configured = "Always true",
    };
};

pub const Status = struct {
    pub const name = "sign_on.status";
    pub const description = "Whether an issuer signs people in here, and which";
    pub const details =
        \\Anyone may call it: the login page asks it where to send you. Unconfigured, the
        \\issuer and audience are empty.
    ;
    pub const kind: operation.Kind = .read;
    pub const open = true;
    pub const In = struct {};
    pub const Out = struct {
        configured: bool,
        issuer: []const u8,
        audience: []const u8,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .configured = true,
        .issuer = "https://publr.app",
        .audience = "a1b2c3d4e5f6a7b8",
    };
    pub const field_docs: operation.Docs(In) = .{};
    pub const output_docs: operation.Docs(Out) = .{
        .configured = "An issuer is trusted",
        .issuer = "Its address",
        .audience = "This site's id in its tokens",
    };
};

pub const Redeem = struct {
    pub const name = "sign_on.redeem";
    /// Never written to the logs.
    pub const secret = .{"token"};
    pub const description = "Sign in with a token the trusted issuer signed";
    pub const details =
        \\Anyone may call it: the token is the credential. It must carry the issuer's
        \\signature, name this site, be unexpired and unused, and name an active account
        \\here; otherwise `wrong email or password`, and a token used twice is a conflict.
        \\Returns a session token, as `user sign_in` does; `/auth/sign-on` sets the cookie.
    ;
    pub const kind: operation.Kind = .write;
    pub const open = true;
    pub const In = struct {
        token: []const u8,
    };
    pub const Out = struct {
        token: []const u8,
        user_id: []const u8,
        expires_at: i64,
    };
    pub const example: In = .{
        .token = "eyJhdWQiOiJhMWIyYzNkNGU1ZjZhN2I4Ii4uLn0.c2lnbmF0dXJl...",
    };
    pub const example_out: Out = .{
        .token = "56a0794f6b1c67062563204a.ea477bba173fbbd2cd5fc9808892da24d65b38...",
        .user_id = "3f9c1e0a5b7d2c4e6f8a9b0c",
        .expires_at = 1792232000000,
    };
    pub const field_docs: operation.Docs(In) = .{
        .token = "The token the issuer signed",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .token = "The session token, `id.secret`; treat it like a password",
        .user_id = "The signed-in account",
        .expires_at = "When the session expires if unused, Unix milliseconds",
    };
};
