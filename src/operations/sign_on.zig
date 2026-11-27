const std = @import("std");
const sdk = @import("../sdk.zig");
const public = @import("../publr/operations/sign_on.zig");
const publr_auth = @import("../sdk/auth_events.zig");
const store = @import("../store.zig");
const signing = @import("signed.zig");
const token_model = @import("../model/sign_on_token.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const issuer_key = "sign_on.issuer";
pub const public_key_key = "sign_on.public_key";
pub const audience_key = "sign_on.audience";
pub const issuer_len_max: u32 = 256;
pub const audience_len_max: u32 = 64;

pub const namespace = public.namespace;

pub const operations = [_]type{ Configure, Status, Redeem };

pub const Configure = struct {
    pub const shape = public.Configure;
    pub const name = shape.name;
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

        if (!valid_issuer(in.issuer) or !valid_audience(in.audience)) {
            return error.Invalid;
        }

        _ = token_model.key_from_hex(in.public_key) catch return error.Invalid;

        try store.settings.set(ctx.db, issuer_key, in.issuer, ctx.now_ms);
        try store.settings.set(ctx.db, public_key_key, in.public_key, ctx.now_ms);
        try store.settings.set(ctx.db, audience_key, in.audience, ctx.now_ms);

        std.debug.assert(in.public_key.len == token_model.key_hex_len);

        return .{
            .configured = true,
        };
    }
};

pub const Status = struct {
    pub const shape = public.Status;
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

    pub fn run(ctx: *Ctx, _: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.now_ms >= 0);

        const issuer = try store.settings.get(ctx.db, ctx.arena, issuer_key) orelse "";
        const audience = try store.settings.get(ctx.db, ctx.arena, audience_key) orelse "";

        return .{
            .configured = issuer.len > 0,
            .issuer = issuer,
            .audience = audience,
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

        const user = try vouched_user(ctx, in.token);

        try signing.before(ctx, user, "link");
        _ = try store.sessions.cleanup(ctx.db, ctx.now_ms);

        const created = try store.sessions.create(ctx.db, ctx.io, ctx.arena, user.id, ctx.now_ms);

        try signing.after(ctx, user, "link");

        return .{
            .token = try ctx.arena.dupe(u8, created.token_text()),
            .user_id = user.id,
            .expires_at = created.session.expires_at,
        };
    }
};

/// The active account a token the trusted issuer signed for this site names, the token
/// used up. `BadCredentials` for a token that is not good, `Conflict` for one used before.
pub fn vouched_user(ctx: *Ctx, token: []const u8) Error!store.users.User {
    std.debug.assert(ctx.db.transaction_depth >= 1);

    const claims = try trusted_claims(ctx, token);

    if (!try store.sign_on_tokens.claim(ctx.db, claims.jti, claims.exp)) {
        ctx.keep(publr_auth.SignOnReplayed, .{
            .email = claims.sub,
        });

        return error.Conflict;
    }

    _ = try store.sign_on_tokens.cleanup(ctx.db, ctx.now_ms);

    const email = store.users.normalize_email(ctx.arena, claims.sub) catch {
        return error.BadCredentials;
    };
    const found = try store.users.find_by_email(ctx.db, ctx.arena, email) orelse {
        return error.BadCredentials;
    };

    if (!found.user.active) {
        return error.BadCredentials;
    }

    std.debug.assert(found.user.id.len > 0);

    return found.user;
}

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
            ctx.keep(publr_auth.SignOnFailed, .{
                .email = "",
                .why = "signature",
            });

            return error.BadCredentials;
        },
    };
    const latest = ctx.now_ms + token_model.lifetime_ms + token_model.clock_skew_ms;
    const in_time = claims.exp > ctx.now_ms and claims.exp <= latest;
    const valid_jti = claims.jti.len > 0 and claims.jti.len <= store.sign_on_tokens.id_len_max;

    if (!std.mem.eql(u8, claims.aud, audience) or !in_time or !valid_jti) {
        ctx.keep(publr_auth.SignOnFailed, .{
            .email = claims.sub,
            .why = "expired",
        });

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
    const seed: [32]u8 = @splat(3);
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
    const other_seed: [32]u8 = @splat(4);
    const forged = try issue(arena, other_seed, "site-one", "ada@example.com", soon, "j5");
    // The issuer's clock a second ahead of the site's: still good; far ahead: never.
    const ahead_ms = anon.now_ms + token_model.lifetime_ms + std.time.ms_per_s;
    const ahead = try issue(arena, seed, "site-one", "ada@example.com", ahead_ms, "j6");
    const far_ms = anon.now_ms + token_model.lifetime_ms + token_model.clock_skew_ms + 1;
    const far = try issue(arena, seed, "site-one", "ada@example.com", far_ms, "j7");
    const signed = try SDK.dispatch(&anon, Redeem, .{
        .token = good,
    });

    try std.testing.expect(signed.token.len > 0);
    try std.testing.expectError(error.Conflict, SDK.dispatch(&anon, Redeem, .{
        .token = good,
    }));
    try std.testing.expect((try SDK.dispatch(&anon, Redeem, .{
        .token = ahead,
    })).token.len > 0);

    for ([_][]const u8{ other_site, expired, stranger, forged, far }) |refused| {
        const answer = SDK.dispatch(&anon, Redeem, .{
            .token = refused,
        });
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
