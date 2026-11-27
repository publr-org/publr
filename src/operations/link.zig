const std = @import("std");
const sdk = @import("../sdk.zig");
const public = @import("../publr/operations/link.zig");
const store = @import("../store.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const Base64 = std.base64.url_safe_no_pad;

/// The setting the site's key for signed links is kept under, hex.
pub const key_setting = "signed_links.key";
pub const subject_len_max = public.subject_len_max;
pub const intent_len_max = public.intent_len_max;
pub const token_len_max = public.token_len_max;

pub const namespace = public.namespace;

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
    pub const shape = public.Sign;
    pub const name = shape.name;
    pub const plugins_only = shape.plugins_only;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

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
    pub const shape = public.Verify;
    pub const name = shape.name;
    pub const plugins_only = shape.plugins_only;
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
    pub const shape = public.RevokeAll;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;

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
