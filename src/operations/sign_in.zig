const std = @import("std");
const sdk = @import("../sdk.zig");
const public = @import("../publr/operations/sign_in.zig");
const publr_auth = @import("../sdk/auth_events.zig");
const auth = @import("../lib/auth.zig");
const store = @import("../store.zig");
const signing = @import("signed.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

/// The session id is the first part of the token; the CSRF token is derived from it.
pub const session_id_len = store.sessions.id_len;

pub const SignIn = struct {
    pub const shape = public.SignIn;
    pub const name = shape.name;
    pub const open = shape.open;
    pub const secret = shape.secret;
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
        std.debug.assert(ctx.now_ms >= 0);

        if (in.password.len > auth.password.len_max) {
            return error.BadCredentials;
        }

        const email = store.users.normalize_email(ctx.arena, in.email) catch |err| switch (err) {
            error.InvalidEmail => return error.BadCredentials,
            else => |other| return other,
        };
        // Counted for the account and the address together where the address is known, so
        // someone guessing from elsewhere cannot keep the account's owner locked out.
        const guesser = if (ctx.address.len == 0)
            email
        else
            try std.mem.concat(ctx.arena, u8, &.{ email, "\n", ctx.address });
        const key = ctx.auth.throttle.key_for(guesser);

        if (ctx.auth.throttle.wait_ms(key, ctx.now_ms) > 0) {
            ctx.keep(publr_auth.SignInThrottled, .{
                .email = email,
            });

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
            ctx.keep(publr_auth.SignInFailed, .{
                .email = email,
            });

            if (ctx.auth.throttle.record_failure(key, ctx.now_ms) > 0) {
                ctx.keep(publr_auth.SignInLocked, .{
                    .email = email,
                });
            }

            return error.BadCredentials;
        }

        ctx.auth.throttle.record_success(key);

        const user_id = found.?.user.id;

        try signing.before(ctx, found.?.user, "password");
        _ = try store.sessions.cleanup(ctx.db, ctx.now_ms);
        const created = try store.sessions.create(ctx.db, ctx.io, ctx.arena, user_id, ctx.now_ms);
        const token = try ctx.arena.dupe(u8, created.token_text());

        try signing.after(ctx, found.?.user, "password");

        return .{
            .token = token,
            .user_id = user_id,
            .roles = found.?.user.roles,
            .expires_at = created.session.expires_at,
        };
    }
};

pub const SignOut = struct {
    pub const shape = public.SignOut;
    pub const name = shape.name;
    pub const open = shape.open;
    pub const secret = shape.secret;
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

        if (in.token.len > 64 << 10) {
            return error.Invalid;
        }

        const lookup = store.sessions.validate(ctx.db, ctx.arena, in.token, ctx.now_ms);
        const validated = lookup catch |err| switch (err) {
            error.SessionNotFound, error.SessionExpired => return .{
                .destroyed = false,
            },
            else => |other| return other,
        };

        try store.sessions.destroy(ctx.db, validated.id);
        try signing.signed_out(ctx, validated.user_id);

        return .{
            .destroyed = true,
        };
    }
};

pub const EndSessions = struct {
    pub const shape = public.EndSessions;
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

        const named = @as(u8, @intFromBool(in.user_id.len > 0)) +
            @intFromBool(in.email.len > 0) + @intFromBool(in.everyone);

        if (named != 1) {
            return error.Invalid;
        }

        if (in.everyone) {
            return .{
                .ended = try store.sessions.destroy_every(ctx.db),
            };
        }

        const user_id = if (in.user_id.len > 0) in.user_id else found: {
            const credentials = try store.users.find_by_email(ctx.db, ctx.arena, in.email);

            break :found if (credentials) |found| found.user.id else return .{
                .ended = 0,
            };
        };

        std.debug.assert(user_id.len > 0);

        return .{
            .ended = try store.sessions.destroy_all(ctx.db, user_id),
        };
    }
};

pub const operations = [_]type{ SignIn, SignOut, EndSessions };

const TestSDK = sdk.SDK(.{
    .operations = &operations,
});

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

    const destroyed = try TestSDK.dispatch(&anon, SignOut, .{
        .token = signed_in.token,
    });
    try std.testing.expect(destroyed.destroyed);
    const again = try TestSDK.dispatch(&anon, SignOut, .{
        .token = signed_in.token,
    });
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

test "throttle: failures from one address do not lock the account's owner out elsewhere" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try @import("user.zig").seed_editor(&system);

    var guesser = harness.ctx(.anonymous);
    var wrong = SignIn.example;

    guesser.address = "203.0.113.7";
    wrong.password = "wrong horse battery";

    for (0..auth.Throttle.failures_free + 1) |_| {
        const refused = TestSDK.dispatch(&guesser, SignIn, wrong);

        try std.testing.expectError(error.BadCredentials, refused);
    }

    const locked = TestSDK.dispatch(&guesser, SignIn, SignIn.example);

    try std.testing.expectError(error.Throttled, locked);

    var owner = harness.ctx(.anonymous);

    owner.address = "203.0.113.8";
    _ = try TestSDK.dispatch(&owner, SignIn, SignIn.example);
}
