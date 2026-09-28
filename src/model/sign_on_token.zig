//! A sign-on token: an issuer (a Publr Cloud dashboard) vouching that someone may sign in to
//! one site, briefly and once. `<payload>.<signature>`, both base64url without padding: the
//! payload is JSON claims, the signature Ed25519 over the payload's text. Sites hold only
//! the issuer's public key, never a secret.

const std = @import("std");

const Ed25519 = std.crypto.sign.Ed25519;
const base64 = std.base64.url_safe_no_pad;

pub const token_len_max: u32 = 1024;
pub const key_hex_len: u32 = 64;
/// How long an issued token is good for: a redirect, not a session.
pub const lifetime_ms: i64 = 60 * std.time.ms_per_s;
/// How far ahead of the site the issuer's clock may be: two machines never agree exactly,
/// and a token signed a moment "later" than the site's now is still one the issuer just
/// made.
pub const clock_skew_ms: i64 = 5 * std.time.ms_per_s;

pub const Claims = struct {
    /// The site it is for: its id, as the site was configured with.
    aud: []const u8,
    /// Who signs in: the account's email.
    sub: []const u8,
    /// Until when, Unix milliseconds.
    exp: i64,
    /// Once only: the site keeps it until `exp`.
    jti: []const u8,
};

pub const Error = error{ Malformed, BadSignature, OutOfMemory };

/// The issuer's side: claims signed with the key pair its seed makes.
pub fn sign(arena: std.mem.Allocator, seed: [32]u8, claims: Claims) Error![]const u8 {
    std.debug.assert(claims.aud.len > 0);
    std.debug.assert(claims.sub.len > 0);

    const pair = Ed25519.KeyPair.generateDeterministic(seed) catch return error.Malformed;
    const json = std.json.Stringify.valueAlloc(arena, claims, .{}) catch return error.OutOfMemory;
    const payload = try encode(arena, json);
    const signature = pair.sign(payload, null) catch return error.Malformed;
    const tail = try encode(arena, &signature.toBytes());

    return std.fmt.allocPrint(arena, "{s}.{s}", .{ payload, tail }) catch error.OutOfMemory;
}

/// The site's side: the claims, when the signature is the issuer's. Whether they are for
/// this site, still valid and unused is the caller's to check.
pub fn verify(arena: std.mem.Allocator, token: []const u8, public_key: [32]u8) Error!Claims {
    std.debug.assert(public_key.len == 32);

    if (token.len == 0 or token.len > token_len_max) {
        return error.Malformed;
    }

    const dot = std.mem.indexOfScalar(u8, token, '.') orelse return error.Malformed;
    const payload = token[0..dot];
    const signature_bytes = try decode(arena, token[dot + 1 ..]);

    if (signature_bytes.len != Ed25519.Signature.encoded_length) {
        return error.Malformed;
    }

    const key = Ed25519.PublicKey.fromBytes(public_key) catch return error.Malformed;
    const signature = Ed25519.Signature.fromBytes(signature_bytes[0..64].*);

    signature.verify(payload, key) catch return error.BadSignature;

    const json = try decode(arena, payload);

    return std.json.parseFromSliceLeaky(Claims, arena, json, .{}) catch error.Malformed;
}

/// The public key a seed makes, as the hex a site is configured with.
pub fn public_key_hex(seed: [32]u8) Error![key_hex_len]u8 {
    const pair = Ed25519.KeyPair.generateDeterministic(seed) catch return error.Malformed;

    return std.fmt.bytesToHex(pair.public_key.toBytes(), .lower);
}

/// 32 bytes from 64 hex characters: a seed or a public key.
pub fn key_from_hex(hex: []const u8) Error![32]u8 {
    comptime std.debug.assert(key_hex_len == 64);

    var bytes: [32]u8 = undefined;

    if (hex.len != key_hex_len) {
        return error.Malformed;
    }

    _ = std.fmt.hexToBytes(&bytes, hex) catch return error.Malformed;

    return bytes;
}

fn encode(arena: std.mem.Allocator, bytes: []const u8) Error![]const u8 {
    const out = arena.alloc(u8, base64.Encoder.calcSize(bytes.len)) catch return error.OutOfMemory;

    return base64.Encoder.encode(out, bytes);
}

fn decode(arena: std.mem.Allocator, text: []const u8) Error![]const u8 {
    std.debug.assert(text.len <= token_len_max);

    const len = base64.Decoder.calcSizeForSlice(text) catch return error.Malformed;
    const out = arena.alloc(u8, len) catch return error.OutOfMemory;

    base64.Decoder.decode(out, text) catch return error.Malformed;

    return out;
}

test "a token signed by the issuer verifies, any change or other key does not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const seed = [_]u8{7} ** 32;
    const other = [_]u8{9} ** 32;
    const claims: Claims = .{ .aud = "site", .sub = "ada@example.com", .exp = 5000, .jti = "j1" };
    const token = try sign(arena, seed, claims);
    const public_key = try key_from_hex(&try public_key_hex(seed));
    const got = try verify(arena, token, public_key);

    try std.testing.expectEqualStrings("ada@example.com", got.sub);
    try std.testing.expectEqualStrings("site", got.aud);
    try std.testing.expectEqual(@as(i64, 5000), got.exp);

    const wrong_key = try key_from_hex(&try public_key_hex(other));
    try std.testing.expectError(error.BadSignature, verify(arena, token, wrong_key));

    // Another account's claims under the issuer's signature: the signature does not fit.
    var other_claims = claims;
    other_claims.sub = "eve@example.com";
    const other_token = try sign(arena, other, other_claims);
    const other_payload = other_token[0..std.mem.indexOfScalar(u8, other_token, '.').?];
    const signature = token[std.mem.indexOfScalar(u8, token, '.').?..];
    const forged = try std.fmt.allocPrint(arena, "{s}{s}", .{ other_payload, signature });

    try std.testing.expectError(error.BadSignature, verify(arena, forged, public_key));

    try std.testing.expectError(error.Malformed, verify(arena, "no-dot", public_key));
    try std.testing.expectError(error.Malformed, key_from_hex("zz"));
}
