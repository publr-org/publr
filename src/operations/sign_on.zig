//! Signing in through someone the site trusts: an issuer (a Publr Cloud dashboard) signs a
//! short-lived token for one account on one site, and the site, holding only the issuer's
//! public key, turns it into an ordinary session. Nothing here needs the issuer to be up
//! once the token exists, and nothing shared is secret.

const std = @import("std");
const sdk = @import("../sdk.zig");
const store = @import("../store.zig");
const token_model = @import("../model/sign_on_token.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const issuer_key = "sign_on.issuer";
pub const public_key_key = "sign_on.public_key";
pub const audience_key = "sign_on.audience";
pub const issuer_len_max: u32 = 256;
pub const audience_len_max: u32 = 64;

pub const namespace: sdk.operation.Namespace = .{
    .name = "sign_on",
    .summary = "Signing in through a trusted issuer, such as a Publr Cloud dashboard",
    .details =
    \\An administrator names the issuer once (`sign_on configure`): its address, its
    \\public key and this site's id in its eyes. From then on a token the issuer signed for
    \\an account of this site (`sign_on redeem`) signs that account in, like a password
    \\would: over HTTP at `/auth/sign-on`, and the admin's login page sends you to the
    \\issuer first.
    ,
};

pub const operations = [_]type{ Configure, Status, Redeem };

pub const Configure = struct {
    pub const name = "sign_on.configure";
    pub const description = "Trust an issuer to sign people in to this site";
    pub const details =
        \\Administrators only. `issuer` is the issuer's address (`https://publr.app`),
        \\`public_key` its Ed25519 public key as 64 hex characters, `audience` this site's
        \\id in its tokens. Configuring again replaces the issuer.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { issuer: []const u8, public_key: []const u8, audience: []const u8 };
    pub const Out = struct { configured: bool };
    pub const example: In = .{
        .issuer = "https://publr.app",
        .public_key = "d04ab232742bb4ab3a1368bd4615e4e6d0224ab71a016baf8520a332c9778737",
        .audience = "a1b2c3d4e5f6a7b8",
    };
    pub const example_out: Out = .{ .configured = true };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .issuer = "The issuer's address, http(s)://host[:port], no path",
        .public_key = "Its Ed25519 public key, 64 hex characters",
        .audience = "This site's id in its tokens",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{ .configured = "Always true" };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (!valid_issuer(in.issuer) or !valid_audience(in.audience)) {
            return error.Invalid;
        }

        _ = token_model.key_from_hex(in.public_key) catch return error.Invalid;

        try store.settings.set(ctx.db, issuer_key, in.issuer, ctx.now_ms);
        try store.settings.set(ctx.db, public_key_key, in.public_key, ctx.now_ms);
        try store.settings.set(ctx.db, audience_key, in.audience, ctx.now_ms);

        std.debug.assert(in.public_key.len == token_model.key_hex_len);

        return .{ .configured = true };
    }
};

pub const Status = struct {
    pub const name = "sign_on.status";
    pub const description = "Whether an issuer signs people in here, and which";
    pub const details =
        \\Anyone may call it: the login page asks it where to send you. Unconfigured, the
        \\issuer and audience are empty.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const open = true;
    pub const In = struct {};
    pub const Out = struct { configured: bool, issuer: []const u8, audience: []const u8 };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .configured = true,
        .issuer = "https://publr.app",
        .audience = "a1b2c3d4e5f6a7b8",
    };
    pub const field_docs: sdk.operation.Docs(In) = .{};
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .configured = "An issuer is trusted",
        .issuer = "Its address",
        .audience = "This site's id in its tokens",
    };

    pub fn run(ctx: *Ctx, _: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.now_ms >= 0);

        const issuer = try store.settings.get(ctx.db, ctx.arena, issuer_key) orelse "";
        const audience = try store.settings.get(ctx.db, ctx.arena, audience_key) orelse "";

        return .{ .configured = issuer.len > 0, .issuer = issuer, .audience = audience };
    }
};

pub const Redeem = struct {
    pub const name = "sign_on.redeem";
    pub const description = "Sign in with a token the trusted issuer signed";
    pub const details =
        \\Anyone may call it: the token is the credential. It must carry the issuer's
        \\signature, name this site, be unexpired and unused, and name an active account
        \\here; otherwise `wrong email or password`, and a token used twice is a conflict.
        \\Returns a session token, as `user sign_in` does; `/auth/sign-on` sets the cookie.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const open = true;
    pub const In = struct { token: []const u8 };
    pub const Out = struct { token: []const u8, user_id: []const u8, expires_at: i64 };
    pub const example: In = .{ .token = "eyJhdWQiOiJhMWIyYzNkNGU1ZjZhN2I4Ii4uLn0.c2lnbmF0dXJl..." };
    pub const example_out: Out = .{
        .token = "56a0794f6b1c67062563204a.ea477bba173fbbd2cd5fc9808892da24d65b38...",
        .user_id = "3f9c1e0a5b7d2c4e6f8a9b0c",
        .expires_at = 1792232000000,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{ .token = "The token the issuer signed" };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .token = "The session token, `id.secret`; treat it like a password",
        .user_id = "The signed-in account",
        .expires_at = "When the session expires if unused, Unix milliseconds",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const claims = try trusted_claims(ctx, in.token);

        if (!try store.sign_on_tokens.claim(ctx.db, claims.jti, claims.exp)) {
            ctx.notice("auth.sign_on_replayed", claims.sub);

            return error.Conflict;
        }

        const email = store.users.normalize_email(ctx.arena, claims.sub) catch {
            return error.BadCredentials;
        };
        const found = try store.users.find_by_email(ctx.db, ctx.arena, email) orelse {
            return error.BadCredentials;
        };

        if (!found.user.active) {
            return error.BadCredentials;
        }

        _ = try store.sessions.cleanup(ctx.db, ctx.now_ms);
        _ = try store.sign_on_tokens.cleanup(ctx.db, ctx.now_ms);

        const user_id = found.user.id;
        const created = try store.sessions.create(ctx.db, ctx.io, ctx.arena, user_id, ctx.now_ms);

        ctx.notice("auth.sign_on_succeeded", found.user.id);

        return .{
            .token = try ctx.arena.dupe(u8, created.token_text()),
            .user_id = found.user.id,
            .expires_at = created.session.expires_at,
        };
    }
};

/// The token's claims when this site's issuer signed them for this site and they are still
/// good; `BadCredentials` for anything else, alike, so nothing tells a forger which part
/// failed.
fn trusted_claims(ctx: *Ctx, token: []const u8) Error!token_model.Claims {
    std.debug.assert(ctx.now_ms >= 0);

    const public_hex = try store.settings.get(ctx.db, ctx.arena, public_key_key) orelse {
        return error.BadCredentials;
    };
    const audience = try store.settings.get(ctx.db, ctx.arena, audience_key) orelse "";
    const public_key = token_model.key_from_hex(public_hex) catch return error.BadCredentials;
    const claims = token_model.verify(ctx.arena, token, public_key) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            ctx.notice("auth.sign_on_failed", "signature");

            return error.BadCredentials;
        },
    };
    const latest = ctx.now_ms + token_model.lifetime_ms + token_model.clock_skew_ms;
    const in_time = claims.exp > ctx.now_ms and claims.exp <= latest;
    const valid_jti = claims.jti.len > 0 and claims.jti.len <= store.sign_on_tokens.id_len_max;

    if (!std.mem.eql(u8, claims.aud, audience) or !in_time or !valid_jti) {
        ctx.notice("auth.sign_on_failed", claims.sub);

        return error.BadCredentials;
    }

    return claims;
}

/// `http(s)://host[:port]`: an origin to send people to, never a path or anything else.
pub fn valid_issuer(issuer: []const u8) bool {
    comptime std.debug.assert(issuer_len_max > "https://".len);

    const rest = if (std.mem.startsWith(u8, issuer, "https://"))
        issuer["https://".len..]
    else if (std.mem.startsWith(u8, issuer, "http://"))
        issuer["http://".len..]
    else
        return false;

    if (rest.len == 0 or issuer.len > issuer_len_max) {
        return false;
    }

    for (rest) |char| {
        const allowed = std.ascii.isAlphanumeric(char) or char == '.' or char == '-' or char == ':';

        if (!allowed) {
            return false;
        }
    }

    return true;
}

fn valid_audience(audience: []const u8) bool {
    comptime std.debug.assert(audience_len_max > 0);

    if (audience.len == 0 or audience.len > audience_len_max) {
        return false;
    }

    for (audience) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '-') {
            return false;
        }
    }

    return true;
}

test "an issuer's token signs its account in once; anything else does not" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const SDK = @import("../server/registry.zig").SDK;
    const user = @import("user.zig");
    const arena = harness.fixed.allocator();
    const seed = [_]u8{3} ** 32;
    const public_hex = try token_model.public_key_hex(seed);
    var system = harness.ctx(.system);
    var anon = harness.ctx(.anonymous);

    try SDK.bootstrap(&system);
    _ = try SDK.dispatch(&system, user.Create, .{
        .email = "ada@example.com",
        .display_name = "Ada",
        .roles = &.{"admin"},
        .password = "correct horse battery",
    });
    _ = try SDK.dispatch(&system, Configure, .{
        .issuer = "https://publr.app",
        .public_key = &public_hex,
        .audience = "site-one",
    });

    const soon = anon.now_ms + 30_000;
    const good = try issue(arena, seed, "site-one", "ada@example.com", soon, "j1");
    const other_site = try issue(arena, seed, "site-two", "ada@example.com", soon, "j2");
    const expired = try issue(arena, seed, "site-one", "ada@example.com", anon.now_ms - 1, "j3");
    const stranger = try issue(arena, seed, "site-one", "eve@example.com", soon, "j4");
    const forged = try issue(arena, [_]u8{4} ** 32, "site-one", "ada@example.com", soon, "j5");
    // The issuer's clock a second ahead of the site's: still good; far ahead: never.
    const ahead_ms = anon.now_ms + token_model.lifetime_ms + std.time.ms_per_s;
    const ahead = try issue(arena, seed, "site-one", "ada@example.com", ahead_ms, "j6");
    const far_ms = anon.now_ms + token_model.lifetime_ms + token_model.clock_skew_ms + 1;
    const far = try issue(arena, seed, "site-one", "ada@example.com", far_ms, "j7");
    const signed = try SDK.dispatch(&anon, Redeem, .{ .token = good });

    try std.testing.expect(signed.token.len > 0);
    try std.testing.expectError(error.Conflict, SDK.dispatch(&anon, Redeem, .{ .token = good }));
    try std.testing.expect((try SDK.dispatch(&anon, Redeem, .{ .token = ahead })).token.len > 0);

    for ([_][]const u8{ other_site, expired, stranger, forged, far }) |refused| {
        const answer = SDK.dispatch(&anon, Redeem, .{ .token = refused });
        try std.testing.expectError(error.BadCredentials, answer);
    }

    const status = try SDK.dispatch(&anon, Status, .{});
    try std.testing.expect(status.configured);
    try std.testing.expectEqualStrings("site-one", status.audience);
    try std.testing.expectError(error.Denied, SDK.dispatch(&anon, Configure, .{
        .issuer = "https://evil.test",
        .public_key = &public_hex,
        .audience = "site-one",
    }));
}

fn issue(
    arena: std.mem.Allocator,
    seed: [32]u8,
    audience: []const u8,
    email: []const u8,
    expires_at: i64,
    jti: []const u8,
) ![]const u8 {
    std.debug.assert(audience.len > 0);

    const claims: token_model.Claims = .{
        .aud = audience,
        .sub = email,
        .exp = expires_at,
        .jti = jti,
    };

    return token_model.sign(arena, seed, claims);
}

test "an issuer is an origin, nothing more" {
    try std.testing.expect(valid_issuer("https://publr.app"));
    try std.testing.expect(valid_issuer("http://publr.localhost:8095"));
    try std.testing.expect(!valid_issuer("publr.app"));
    try std.testing.expect(!valid_issuer("https://publr.app/evil"));
    try std.testing.expect(!valid_issuer("https://publr.app?x=1"));
    try std.testing.expect(!valid_issuer("javascript:alert(1)"));
}
