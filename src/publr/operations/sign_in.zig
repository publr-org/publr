//! Signing in with an email and a password, and out: `user.sign_in`, `user.sign_out`.
const operation = @import("../operation.zig");

pub const SignIn = struct {
    pub const name = "user.sign_in";
    pub const open = true;
    /// Never written to the logs.
    pub const secret = .{"password"};
    pub const description = "Sign in with email and password; returns a session token";
    pub const details =
        \\Anyone may call it (no `--as`). Over HTTP this is `POST /api/auth/sign-in`, which
        \\also sets the `publr_session` cookie; from the CLI you get the raw token,
        \\which is what that cookie holds. Sessions last thirty days and extend on use.
        \\
        \\A wrong password and an unknown email give the same answer, `wrong email or
        \\password`. After a few failures the account waits before it may try again
        \\(one minute, then five, fifteen, sixty), never permanently: `too many failed
        \\attempts`. The wait is for the address the failures came from, so the account's
        \\owner still signs in from elsewhere. Inactive accounts (link not redeemed yet)
        \\cannot sign in.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        email: []const u8,
        password: []const u8,
    };
    pub const Out = struct {
        token: []const u8,
        user_id: []const u8,
        roles: []const []const u8,
        expires_at: i64,
    };
    pub const example: In = .{
        .email = "editor@example.com",
        .password = "correct horse battery",
    };
    pub const example_out: Out = .{
        .token = "56a0794f6b1c67062563204a.ea477bba173fbbd2cd5fc9808892da24d65b38...",
        .user_id = "3f9c1e0a5b7d2c4e6f8a9b0c",
        .roles = &.{"editor"},
        .expires_at = 1792232000000,
    };
    pub const field_docs: operation.Docs(In) = .{
        .email = "The account's email (case does not matter)",
        .password = "The account's password (or `PUBLR_PASSWORD`)",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .token = "The session token, `id.secret`; treat it like a password",
        .user_id = "The signed-in account",
        .roles = "The roles it holds",
        .expires_at = "When the session expires if unused, Unix milliseconds",
    };
};

pub const SignOut = struct {
    pub const name = "user.sign_out";
    pub const open = true;
    /// Never written to the logs.
    pub const secret = .{"token"};
    pub const description = "Sign out: revoke a session token";
    pub const details =
        \\Anyone holding the token may call it; over HTTP this is `POST /api/auth/sign-out`
        \\for the cookie's session. Revoking an unknown or already expired token is not
        \\an error: `destroyed` is simply false.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        token: []const u8,
    };
    pub const Out = struct {
        destroyed: bool,
    };
    pub const example: In = .{
        .token = "0123456789abcdef01234567.not-a-real-secret",
    };
    pub const example_out: Out = .{
        .destroyed = false,
    };
    pub const field_docs: operation.Docs(In) = .{
        .token = "The session token from `user sign_in`",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .destroyed = "True when a live session was revoked",
    };
};
