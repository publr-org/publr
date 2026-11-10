//! OAuth for MCP clients (a tool adding Publr by its address): which clients there are, where
//! they may be sent back, and the PKCE check that binds a code to the client that asked.
//!
//! Registration is open to anyone (RFC 7591), so a client's id carries the client itself: its
//! name and return addresses, encoded. Nothing is stored for it, so registering cannot fill
//! the database; what protects the person is the approve page, which names the client and
//! where it sends them back.

const std = @import("std");
const device = @import("device.zig");

pub const client_prefix = "pc_";
pub const redirect_uris_max: u32 = 8;
pub const uri_len_max: u32 = 512;
pub const client_id_len_max: u32 = 8 << 10;
pub const verifier_len_min: u32 = 43;
pub const verifier_len_max: u32 = 128;
pub const challenge_len: u32 = 43;

const base64 = std.base64.url_safe_no_pad;

pub const Client = struct {
    name: []const u8,
    redirect_uris: []const []const u8,
};

/// Where a client may be sent back: `https://`, `http://` to this machine (a tool's own
/// callback), or a tool's own scheme (`cursor://…`); never a fragment, never a scheme that
/// runs or reads something in the browser.
pub fn valid_redirect(uri: []const u8) bool {
    std.debug.assert(uri_len_max > 0);

    if (uri.len == 0 or uri.len > uri_len_max) {
        return false;
    }

    for (uri) |byte| {
        if (byte <= ' ' or byte == '#' or byte == 0x7f) {
            return false;
        }
    }

    const colon = std.mem.indexOfScalar(u8, uri, ':') orelse return false;
    const scheme = uri[0..colon];

    if (!valid_scheme(scheme) or !std.mem.startsWith(u8, uri[colon..], "://")) {
        return false;
    }

    if (std.ascii.eqlIgnoreCase(scheme, "https")) {
        return uri.len > "https://".len;
    }

    if (std.ascii.eqlIgnoreCase(scheme, "http")) {
        return loopback(uri["http://".len..]);
    }

    const refused = [_][]const u8{ "javascript", "data", "file", "vbscript", "blob", "about" };

    for (refused) |name| {
        if (std.ascii.eqlIgnoreCase(scheme, name)) {
            return false;
        }
    }

    return true;
}

fn valid_scheme(scheme: []const u8) bool {
    std.debug.assert(scheme.len <= uri_len_max);

    if (scheme.len == 0 or !std.ascii.isAlphabetic(scheme[0])) {
        return false;
    }

    for (scheme) |char| {
        const allowed = std.ascii.isAlphanumeric(char) or char == '+' or char == '-' or
            char == '.';

        if (!allowed) {
            return false;
        }
    }

    return true;
}

/// `localhost`, `127.0.0.1` or `[::1]`, with a port or a path after it, or nothing.
fn loopback(rest: []const u8) bool {
    std.debug.assert(rest.len <= uri_len_max);

    const hosts = [_][]const u8{ "localhost", "127.0.0.1", "[::1]" };

    for (hosts) |host| {
        if (!std.mem.startsWith(u8, rest, host)) {
            continue;
        }

        const after = rest[host.len..];

        if (after.len == 0 or after[0] == ':' or after[0] == '/') {
            return true;
        }
    }

    return false;
}

/// The client's id: its name and return addresses, one per line, encoded.
pub fn client_id_of(arena: std.mem.Allocator, client: Client) error{ OutOfMemory, Invalid }![]u8 {
    std.debug.assert(redirect_uris_max > 0);

    if (!valid(client)) {
        return error.Invalid;
    }

    var plain: std.Io.Writer.Allocating = .init(arena);

    plain.writer.writeAll(client.name) catch return error.OutOfMemory;

    for (client.redirect_uris) |uri| {
        plain.writer.print("\n{s}", .{uri}) catch return error.OutOfMemory;
    }

    const text = plain.written();
    const encoded = try arena.alloc(u8, client_prefix.len + base64.Encoder.calcSize(text.len));

    @memcpy(encoded[0..client_prefix.len], client_prefix);
    _ = base64.Encoder.encode(encoded[client_prefix.len..], text);

    std.debug.assert(encoded.len <= client_id_len_max);

    return encoded;
}

/// The client an id carries; null for an id no registration here made.
pub fn client_of(arena: std.mem.Allocator, client_id: []const u8) error{OutOfMemory}!?Client {
    std.debug.assert(client_prefix.len > 0);

    if (client_id.len > client_id_len_max or !std.mem.startsWith(u8, client_id, client_prefix)) {
        return null;
    }

    const encoded = client_id[client_prefix.len..];
    const size = base64.Decoder.calcSizeForSlice(encoded) catch return null;
    const text = try arena.alloc(u8, size);

    base64.Decoder.decode(text, encoded) catch return null;

    var lines = std.mem.splitScalar(u8, text, '\n');
    const name = lines.first();
    var uris: std.ArrayList([]const u8) = .empty;

    while (lines.next()) |uri| {
        if (uris.items.len == redirect_uris_max) {
            return null;
        }

        try uris.append(arena, uri);
    }

    const client: Client = .{
        .name = name,
        .redirect_uris = uris.items,
    };

    return if (valid(client)) client else null;
}

fn valid(client: Client) bool {
    std.debug.assert(redirect_uris_max > 0);

    if (!device.valid_name(client.name) or std.mem.indexOfScalar(u8, client.name, '\n') != null) {
        return false;
    }

    if (client.redirect_uris.len == 0 or client.redirect_uris.len > redirect_uris_max) {
        return false;
    }

    for (client.redirect_uris) |uri| {
        if (!valid_redirect(uri)) {
            return false;
        }
    }

    return true;
}

/// Whether `uri` is one the client registered, exactly.
pub fn registered(client: Client, uri: []const u8) bool {
    std.debug.assert(client.redirect_uris.len > 0);

    for (client.redirect_uris) |known| {
        if (std.mem.eql(u8, known, uri)) {
            return true;
        }
    }

    return false;
}

/// A PKCE challenge as clients send it: S256, 43 base64url characters.
pub fn valid_challenge(challenge: []const u8) bool {
    std.debug.assert(challenge_len == base64.Encoder.calcSize(32));

    if (challenge.len != challenge_len) {
        return false;
    }

    for (challenge) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '-' and char != '_') {
            return false;
        }
    }

    return true;
}

/// Whether the verifier is the one the challenge was made from (S256).
pub fn verifies(verifier: []const u8, challenge: []const u8) bool {
    std.debug.assert(challenge_len > 0);

    if (verifier.len < verifier_len_min or verifier.len > verifier_len_max) {
        return false;
    }

    if (!valid_challenge(challenge)) {
        return false;
    }

    var digest: [32]u8 = undefined;
    var expected: [challenge_len]u8 = undefined;

    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    _ = base64.Encoder.encode(&expected, &digest);

    return std.crypto.timing_safe.eql([challenge_len]u8, expected, challenge[0..challenge_len].*);
}

test "return addresses: https, this machine, a tool's own scheme" {
    try std.testing.expect(valid_redirect("https://claude.ai/api/mcp/auth_callback"));
    try std.testing.expect(valid_redirect("http://localhost:8787/callback"));
    try std.testing.expect(valid_redirect("http://127.0.0.1:53000/cb"));
    try std.testing.expect(valid_redirect("http://[::1]:4000/"));
    try std.testing.expect(valid_redirect("cursor://anysphere.cursor-mcp/oauth/callback"));
    try std.testing.expect(!valid_redirect("http://example.com/callback"));
    try std.testing.expect(!valid_redirect("http://localhost.example.com/cb"));
    try std.testing.expect(!valid_redirect("https://example.com/cb#x"));
    try std.testing.expect(!valid_redirect("javascript://alert(1)"));
    try std.testing.expect(!valid_redirect("data://text/html"));
    try std.testing.expect(!valid_redirect("https://"));
    try std.testing.expect(!valid_redirect("https://exa mple.com"));
    try std.testing.expect(!valid_redirect("mailto:ada@example.com"));
    try std.testing.expect(!valid_redirect(""));
}

test "a client's id carries the client, and only a valid one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const uris = [_][]const u8{ "http://localhost:8787/callback", "cursor://anysphere/cb" };
    const id = try client_id_of(arena, .{
        .name = "Cursor",
        .redirect_uris = &uris,
    });
    const client = (try client_of(arena, id)).?;

    try std.testing.expectEqualStrings("Cursor", client.name);
    try std.testing.expectEqual(@as(usize, 2), client.redirect_uris.len);
    try std.testing.expect(registered(client, "cursor://anysphere/cb"));
    try std.testing.expect(!registered(client, "cursor://anysphere/cb2"));

    try std.testing.expect(try client_of(arena, "pc_!!!") == null);
    try std.testing.expect(try client_of(arena, "other") == null);
    try std.testing.expectError(error.Invalid, client_id_of(arena, .{
        .name = "Evil",
        .redirect_uris = &.{"http://example.com/cb"},
    }));
    try std.testing.expectError(error.Invalid, client_id_of(arena, .{
        .name = "",
        .redirect_uris = &uris,
    }));
}

test "a verifier matches only its own challenge" {
    // RFC 7636, appendix B.
    const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
    const challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM";

    try std.testing.expect(valid_challenge(challenge));
    try std.testing.expect(verifies(verifier, challenge));
    try std.testing.expect(!verifies(verifier ++ "x", challenge));
    try std.testing.expect(!verifies("short", challenge));
    try std.testing.expect(!valid_challenge("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-c+"));
}
