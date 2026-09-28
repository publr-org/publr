const std = @import("std");
const sdk = @import("../sdk.zig");
const auth = @import("../lib/auth.zig");
const store = @import("../store.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

/// The session id is the first part of the token; the CSRF token is derived from it.
pub const session_id_len = store.sessions.id_len;

pub const SignIn = struct {
    pub const name = "user.sign_in";
    pub const description = "Sign in with email and password; returns a session token";
    pub const details =
        \\Anyone may call it (no `--as`). Over HTTP this is `POST /api/auth/sign-in`, which
        \\also sets the `publr_session` cookie; from the CLI you get the raw token,
        \\which is what that cookie holds. Sessions last thirty days and extend on use.
        \\
        \\A wrong password and an unknown email give the same answer, `wrong email or
        \\password`. After a few failures the account waits before it may try again
        \\(one minute, then five, fifteen, sixty), never permanently: `too many failed
        \\attempts`. Inactive accounts (link not redeemed yet) cannot sign in.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { email: []const u8, password: []const u8 };
    pub const Out = struct { token: []const u8, user_id: []const u8, expires_at: i64 };
    pub const example: In = .{ .email = "editor@example.com", .password = "correct horse battery" };
    pub const example_out: Out = .{
        .token = "56a0794f6b1c67062563204a.ea477bba173fbbd2cd5fc9808892da24d65b38...",
        .user_id = "3f9c1e0a5b7d2c4e6f8a9b0c",
        .expires_at = 1792232000000,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .email = "The account's email (case does not matter)",
        .password = "The account's password (or `PUBLR_PASSWORD`)",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .token = "The session token, `id.secret`; treat it like a password",
        .user_id = "The signed-in account",
        .expires_at = "When the session expires if unused, Unix milliseconds",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);
        std.debug.assert(ctx.now_ms >= 0);

        if (in.password.len > auth.password.len_max) {
            return error.BadCredentials;
        }

        const email = store.users.normalize_email(ctx.arena, in.email) catch |err| switch (err) {
            error.InvalidEmail => return error.BadCredentials,
            else => |other| return other,
        };
        const key = ctx.auth.throttle.key_for(email);

        if (ctx.auth.throttle.wait_ms(key, ctx.now_ms) > 0) {
            ctx.notice("auth.sign_in_throttled", email);

            return error.Throttled;
        }

        const found = try store.users.find_by_email(ctx.db, ctx.arena, email);
        const active_hash: ?[]const u8 = if (found) |credentials|
            credentials.password_hash
        else
            null;
        const stored_hash = active_hash orelse ctx.auth.dummy_hash();
        const verified = ctx.auth.verify_password(stored_hash, in.password, ctx.io);

        if (active_hash == null or !verified) {
            ctx.notice("auth.sign_in_failed", email);
            if (ctx.auth.throttle.record_failure(key, ctx.now_ms) > 0) {
                ctx.notice("auth.sign_in_locked", email);
            }

            return error.BadCredentials;
        }

        ctx.auth.throttle.record_success(key);

        const user_id = found.?.user.id;
        _ = try store.sessions.cleanup(ctx.db, ctx.now_ms);
        const created = try store.sessions.create(ctx.db, ctx.io, ctx.arena, user_id, ctx.now_ms);
        const token = try ctx.arena.dupe(u8, created.token_text());

        ctx.notice("auth.sign_in_succeeded", user_id);

        return .{ .token = token, .user_id = user_id, .expires_at = created.session.expires_at };
    }
};

pub const SignOut = struct {
    pub const name = "user.sign_out";
    pub const description = "Sign out: revoke a session token";
    pub const details =
        \\Anyone holding the token may call it; over HTTP this is `POST /api/auth/sign-out`
        \\for the cookie's session. Revoking an unknown or already expired token is not
        \\an error: `destroyed` is simply false.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { token: []const u8 };
    pub const Out = struct { destroyed: bool };
    pub const example: In = .{ .token = "0123456789abcdef01234567.not-a-real-secret" };
    pub const example_out: Out = .{ .destroyed = false };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .token = "The session token from `user sign_in`",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .destroyed = "True when a live session was revoked",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.token.len > 64 << 10) {
            return error.Invalid;
        }

        const lookup = store.sessions.validate(ctx.db, ctx.arena, in.token, ctx.now_ms);
        const validated = lookup catch |err| switch (err) {
            error.SessionNotFound, error.SessionExpired => return .{ .destroyed = false },
            else => |other| return other,
        };

        try store.sessions.destroy(ctx.db, validated.id);
        ctx.notice("auth.sign_out", validated.user_id);

        return .{ .destroyed = true };
    }
};

pub const operations = [_]type{ SignIn, SignOut };

const TestSDK = sdk.SDK(.{ .operations = &operations });

test "create: right password signs in, wrong password and unknown email fail alike; destroy" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try @import("user.zig").seed_editor(&system);

    var anon = harness.ctx(.anonymous);
    const signed_in = try TestSDK.dispatch(&anon, SignIn, SignIn.example);
    try std.testing.expectEqual(@as(usize, store.sessions.token_len), signed_in.token.len);
    try std.testing.expectEqual(store.sessions.lifetime_ms, signed_in.expires_at);

    var wrong = SignIn.example;
    wrong.password = "wrong horse battery";
    try std.testing.expectError(error.BadCredentials, TestSDK.dispatch(&anon, SignIn, wrong));

    var unknown = SignIn.example;
    unknown.email = "nobody@example.com";
    try std.testing.expectError(error.BadCredentials, TestSDK.dispatch(&anon, SignIn, unknown));

    const destroyed = try TestSDK.dispatch(&anon, SignOut, .{ .token = signed_in.token });
    try std.testing.expect(destroyed.destroyed);
    const again = try TestSDK.dispatch(&anon, SignOut, .{ .token = signed_in.token });
    try std.testing.expect(!again.destroyed);
}

test "throttle: five failures lock the account for a minute, success clears it" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try @import("user.zig").seed_editor(&system);

    var anon = harness.ctx(.anonymous);
    var wrong = SignIn.example;
    wrong.password = "wrong horse battery";

    var attempt: u32 = 0;

    while (attempt < auth.Throttle.failures_free + 1) : (attempt += 1) {
        try std.testing.expectError(error.BadCredentials, TestSDK.dispatch(&anon, SignIn, wrong));
    }

    try std.testing.expectError(error.Throttled, TestSDK.dispatch(&anon, SignIn, SignIn.example));

    var later = harness.ctx(.anonymous);
    later.now_ms = 60_001;
    _ = try TestSDK.dispatch(&later, SignIn, SignIn.example);
    try std.testing.expectError(error.BadCredentials, TestSDK.dispatch(&later, SignIn, wrong));
    _ = try TestSDK.dispatch(&later, SignIn, SignIn.example);
}
