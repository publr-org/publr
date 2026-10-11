//! A preview's pass: who opened the preview of which record, until when, signed with the
//! project's secret. It stands in for the session inside the preview's sandboxed frame, where
//! the session cookie never goes, and opens nothing but the preview: the record's page and
//! the pages it links to, drawn from their edit copies.
//!
//! `<record>.<user>.<expires_ms>.<mac>`: the record's id (or `new`), the user's id, when it
//! stops working, and the HMAC-SHA256 of the three, in hex.
const std = @import("std");

const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;

pub const lifetime_ms: i64 = 60 * 60 * 1000;
pub const part_len_max: u32 = 64;
pub const mac_hex_len: u32 = Hmac.mac_length * 2;
pub const text_len_max: u32 = 3 * part_len_max + 20 + mac_hex_len + 3;

pub const Claims = struct {
    /// The record previewed, or `new` for one not saved yet.
    record: []const u8,
    user: []const u8,
    expires_ms: i64,
};

pub fn sign(arena: std.mem.Allocator, secret: []const u8, claims: Claims) ![]const u8 {
    std.debug.assert(secret.len > 0);
    std.debug.assert(plain(claims.record) and plain(claims.user));

    const body = try std.fmt.allocPrint(arena, "{s}.{s}.{d}", .{
        claims.record,
        claims.user,
        claims.expires_ms,
    });
    var mac: [Hmac.mac_length]u8 = undefined;

    Hmac.create(&mac, body, secret);

    return std.fmt.allocPrint(arena, "{s}.{x}", .{ body, mac });
}

/// The claims of a pass that is whole, signed with `secret` and not expired; null otherwise.
pub fn verify(text: []const u8, secret: []const u8, now_ms: i64) ?Claims {
    std.debug.assert(secret.len > 0);
    std.debug.assert(now_ms > 0);

    if (text.len == 0 or text.len > text_len_max) {
        return null;
    }

    const cut = std.mem.lastIndexOfScalar(u8, text, '.') orelse return null;
    const body = text[0..cut];
    const given = text[cut + 1 ..];
    var parts = std.mem.splitScalar(u8, body, '.');
    const record = parts.next() orelse return null;
    const user = parts.next() orelse return null;
    const expires_text = parts.next() orelse return null;

    if (parts.next() != null or !plain(record) or !plain(user) or given.len != mac_hex_len) {
        return null;
    }

    var expected: [Hmac.mac_length]u8 = undefined;
    var received: [Hmac.mac_length]u8 = undefined;

    Hmac.create(&expected, body, secret);
    _ = std.fmt.hexToBytes(&received, given) catch return null;

    if (!std.crypto.timing_safe.eql([Hmac.mac_length]u8, expected, received)) {
        return null;
    }

    const expires_ms = std.fmt.parseInt(i64, expires_text, 10) catch return null;

    if (expires_ms <= now_ms) {
        return null;
    }

    return .{
        .record = record,
        .user = user,
        .expires_ms = expires_ms,
    };
}

/// An id as a pass carries it: letters and digits only, so it never breaks the pass apart.
fn plain(part: []const u8) bool {
    std.debug.assert(part_len_max > 0);

    if (part.len == 0 or part.len > part_len_max) {
        return false;
    }

    for (part) |char| {
        if (!std.ascii.isAlphanumeric(char)) {
            return false;
        }
    }

    return true;
}

test "a pass opens until it expires, and only as signed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const secret = "s3cret-of-the-project";
    const pass = try sign(arena, secret, .{
        .record = "01a118da3dc80000d7d8715f",
        .user = "u1",
        .expires_ms = 2_000,
    });
    const claims = verify(pass, secret, 1_000).?;

    try std.testing.expectEqualStrings("01a118da3dc80000d7d8715f", claims.record);
    try std.testing.expectEqualStrings("u1", claims.user);
    try std.testing.expect(verify(pass, secret, 2_000) == null);
    try std.testing.expect(verify(pass, "another-secret", 1_000) == null);

    const forged = try std.mem.replaceOwned(u8, arena, pass, "u1.", "u2.");

    try std.testing.expect(verify(forged, secret, 1_000) == null);
    try std.testing.expect(verify("new.u1.5", secret, 1_000) == null);
    try std.testing.expect(verify("", secret, 1_000) == null);
}

test "only plain ids are signed" {
    try std.testing.expect(plain("new"));
    try std.testing.expect(!plain("a.b"));
    try std.testing.expect(!plain(""));
}
