//! Signed links: a plugin signs what a link may do (its intent, the record it is for, until
//! when) so a person opens it without signing in: unsubscribe, a cart restored, an invoice,
//! a withdrawal. The signature is keyed by a secret the site keeps and no plugin holds;
//! `link.revoke_all` draws a new one, and every link signed before stops working. An
//! intent is its plugin's own (`<plugin>.<intent>`): no plugin signs or reads another's.
//! A link `/_links/<token>` runs the plugin's operation the intent names, as the plugin,
//! given the subject.
const std = @import("std");
const sdk = @import("../sdk.zig");
const store = @import("../store.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const Base64 = std.base64.url_safe_no_pad;

/// The setting the site's key for signed links is kept under, hex.
pub const key_setting = "signed_links.key";
pub const subject_len_max: u32 = 256;
pub const intent_len_max: u32 = 96;
pub const token_len_max: u32 = 1024;

pub const namespace: sdk.operation.Namespace = .{
    .name = "link",
    .label = "Signed links",
    .area = .system,
    .summary = "Links a person opens without signing in, signed for one purpose",
    .details =
    \\A plugin signs a link for one purpose (its intent: `unsubscribe`), one subject (a
    \\subscriber's id) and a time it stops working; the site checks it when it is opened.
    \\Only the plugin that signed a link reads it. `link revoke_all` stops every link signed
    \\so far. A link opened at `/_links/<token>` runs the operation its intent names.
    ,
};

pub const operations = [_]type{ Sign, Verify, RevokeAll };

/// What a token carries, before its signature.
const Claims = struct {
    /// `<plugin>.<intent>`
    intent: []const u8,
    subject: []const u8,
    /// When it stops working, ms; 0 never
    expires_at: i64 = 0,
};

pub const Sign = struct {
    pub const name = "link.sign";
    pub const plugins_only = true;
    pub const description = "Sign a link for one purpose and one subject, until a time";
    pub const details =
        \\Plugins only. The intent is the plugin's own (`unsubscribe` is kept as
        \\`<plugin>.unsubscribe`), so only it reads the token back (`link.verify`) and a
        \\link to `/_links/<token>` runs its operation of that name. `expires_at` of 0 keeps
        \\it working until `link revoke_all`.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        intent: []const u8,
        subject: []const u8,
        expires_at: i64 = 0,
    };
    pub const Out = struct {
        token: []const u8,
        path: []const u8,
    };
    pub const example: In = .{
        .intent = "unsubscribe",
        .subject = "9b1e7c3d5a2f4e6b8d0c1a3f",
    };
    pub const example_out: Out = .{
        .token = "eyJpIjoibmV3c2xldHRlci51bnN1YnNjcmliZSJ9.Qm9i",
        .path = "/_links/eyJpIjoibmV3c2xldHRlci51bnN1YnNjcmliZSJ9.Qm9i",
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .intent = "What the link may do, the plugin's own word: `unsubscribe`",
        .subject = "What it is for: a record's id, an email",
        .expires_at = "When it stops working (ms since 1970); 0 never",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .token = "The signed token",
        .path = "The link opening it, from the site's root",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const intent = try intent_of(ctx, in.intent);

        if (in.subject.len == 0 or in.subject.len > subject_len_max or in.expires_at < 0) {
            return error.Invalid;
        }

        const key = try key_of(ctx, true) orelse return error.Unavailable;
        const token = try sign(ctx.arena, key, .{
            .intent = intent,
            .subject = in.subject,
            .expires_at = in.expires_at,
        });

        return .{
            .token = token,
            .path = try std.mem.concat(ctx.arena, u8, &.{ "/_links/", token }),
        };
    }
};

pub const Verify = struct {
    pub const name = "link.verify";
    pub const plugins_only = true;
    /// Never written to the logs.
    pub const secret = .{"token"};
    pub const description = "Read a signed link's subject back, when it is good for the intent";
    pub const details =
        \\Plugins only, for their own intents. Answers the subject the link was signed for;
        \\not found when the token is not one the site signed for this intent and plugin,
        \\has stopped working, or was revoked.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        intent: []const u8,
        token: []const u8,
    };
    pub const Out = struct {
        subject: []const u8,
        expires_at: i64,
    };
    pub const example: In = .{
        .intent = "unsubscribe",
        .token = "eyJpIjoibmV3c2xldHRlci51bnN1YnNjcmliZSJ9.Qm9i",
    };
    pub const example_out: Out = .{
        .subject = "9b1e7c3d5a2f4e6b8d0c1a3f",
        .expires_at = 0,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .intent = "The plugin's word it was signed for",
        .token = "The token from the link",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .subject = "What it was signed for",
        .expires_at = "When it stops working; 0 never",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        const intent = try intent_of(ctx, in.intent);
        const claims = try verified(ctx, in.token) orelse return error.NotFound;

        if (!std.mem.eql(u8, claims.intent, intent)) {
            return error.NotFound;
        }

        return .{
            .subject = claims.subject,
            .expires_at = claims.expires_at,
        };
    }
};

pub const RevokeAll = struct {
    pub const name = "link.revoke_all";
    pub const description = "Stop every signed link the site gave out so far";
    pub const details =
        \\Administrators only. The site draws a new key: every link signed before (an
        \\unsubscribe, a cart, an invoice) stops working; links signed from now on work.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {};
    pub const Out = struct {};
    pub const example: In = .{};
    pub const example_out: Out = .{};

    pub fn run(ctx: *Ctx, _: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        try store.settings.delete(ctx.db, key_setting);
        _ = try key_of(ctx, true);

        return .{};
    }
};

/// A token's claims when the site signed it and it still works; null otherwise.
pub fn verified(ctx: *Ctx, token: []const u8) Error!?Claims {
    std.debug.assert(ctx.now_ms >= 0);
    std.debug.assert(token.len <= 1 << 20);

    if (token.len == 0 or token.len > token_len_max) {
        return null;
    }

    const key = try key_of(ctx, false) orelse return null;
    const dot = std.mem.indexOfScalar(u8, token, '.') orelse return null;
    var expected: [Hmac.mac_length]u8 = undefined;
    var given: [Hmac.mac_length]u8 = undefined;

    Hmac.create(&expected, token[0..dot], &key);

    const signature_size = Base64.Decoder.calcSizeForSlice(token[dot + 1 ..]) catch return null;

    if (signature_size != Hmac.mac_length) {
        return null;
    }

    Base64.Decoder.decode(&given, token[dot + 1 ..]) catch return null;

    if (!std.crypto.timing_safe.eql([Hmac.mac_length]u8, expected, given)) {
        return null;
    }

    const size = Base64.Decoder.calcSizeForSlice(token[0..dot]) catch return null;
    const text = try ctx.arena.alloc(u8, size);

    Base64.Decoder.decode(text, token[0..dot]) catch return null;

    const claims = std.json.parseFromSliceLeaky(Claims, ctx.arena, text, .{
        .allocate = .alloc_always,
    }) catch return null;

    if (claims.expires_at != 0 and claims.expires_at <= ctx.now_ms) {
        return null;
    }

    return claims;
}

fn sign(arena: std.mem.Allocator, key: [32]u8, claims: Claims) Error![]const u8 {
    std.debug.assert(claims.intent.len > 0);
    std.debug.assert(claims.subject.len > 0);

    const text = std.json.Stringify.valueAlloc(arena, claims, .{}) catch {
        return error.OutOfMemory;
    };
    const body = try arena.alloc(u8, Base64.Encoder.calcSize(text.len));
    var mac: [Hmac.mac_length]u8 = undefined;

    _ = Base64.Encoder.encode(body, text);
    Hmac.create(&mac, body, &key);

    const signature = try arena.alloc(u8, Base64.Encoder.calcSize(mac.len));

    _ = Base64.Encoder.encode(signature, &mac);

    return std.mem.concat(arena, u8, &.{ body, ".", signature });
}

/// `<plugin>.<intent>` for the calling plugin; refused for anyone else.
fn intent_of(ctx: *Ctx, intent: []const u8) Error![]const u8 {
    std.debug.assert(ctx.now_ms >= 0);
    std.debug.assert(intent.len <= 1 << 20);

    const plugin = switch (ctx.caller) {
        .plugin => |caller| caller.name,
        else => ctx.plugin,
    };

    if (plugin.len == 0) {
        return error.Denied;
    }

    if (intent.len == 0 or intent.len > intent_len_max) {
        return error.Invalid;
    }

    return std.mem.concat(ctx.arena, u8, &.{ plugin, ".", intent });
}

/// The site's key for signed links, drawn the first time one is signed (`make`).
fn key_of(ctx: *Ctx, make: bool) Error!?[32]u8 {
    std.debug.assert(key_setting.len > 0);
    std.debug.assert(!make or ctx.db.transaction_depth >= 1);

    var key: [32]u8 = undefined;

    if (try store.settings.get(ctx.db, ctx.arena, key_setting)) |hex| {
        _ = std.fmt.hexToBytes(&key, hex) catch return error.Invalid;

        return key;
    }

    if (!make) {
        return null;
    }

    ctx.io.random(&key);

    const hex = std.fmt.bytesToHex(key, .lower);

    try store.settings.set(ctx.db, key_setting, &hex, ctx.now_ms);

    return key;
}

test "a link signed for one intent reads back for it alone, until it stops or is revoked" {
    const TestSDK = sdk.SDK(.{
        .operations = &operations,
    });
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var plugin = harness.ctx(.system);

    plugin.plugin = "newsletter";

    const signed = try TestSDK.dispatch(&plugin, Sign, .{
        .intent = "unsubscribe",
        .subject = "ada@example.com",
        .expires_at = plugin.now_ms + 1000,
    });
    const read = try TestSDK.dispatch(&plugin, Verify, .{
        .intent = "unsubscribe",
        .token = signed.token,
    });

    try std.testing.expectEqualStrings("ada@example.com", read.subject);
    try std.testing.expectError(error.NotFound, TestSDK.dispatch(&plugin, Verify, .{
        .intent = "restore",
        .token = signed.token,
    }));

    var other = harness.ctx(.system);

    other.plugin = "carts";
    try std.testing.expectError(error.NotFound, TestSDK.dispatch(&other, Verify, .{
        .intent = "unsubscribe",
        .token = signed.token,
    }));

    const tampered = try plugin.arena.dupe(u8, signed.token);

    tampered[2] = if (tampered[2] == 'A') 'B' else 'A';
    try std.testing.expect(try verified(&plugin, tampered) == null);

    var later = harness.ctx(.system);

    later.now_ms = plugin.now_ms + 2000;
    try std.testing.expect(try verified(&later, signed.token) == null);

    _ = try TestSDK.dispatch(&plugin, RevokeAll, .{});
    try std.testing.expect(try verified(&plugin, signed.token) == null);
}
