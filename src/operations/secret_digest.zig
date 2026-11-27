const std = @import("std");
const sdk = @import("../sdk.zig");
const public = @import("../publr/operations/secret/digest.zig");
const model = @import("../model.zig");
const http = @import("http.zig");
const secret = @import("secret.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const secrets = model.secrets;
const hash = std.crypto.hash;
const hmac = std.crypto.auth.hmac;

pub const text_bytes_max = public.text_bytes_max;
pub const chain_max = public.chain_max;
const secrets_max: u32 = 8;
/// The longest digest, SHA-512 in hex.
const digest_bytes_max: u32 = 128;

pub const Algorithm = public.Algorithm;
pub const Encoding = public.Encoding;

/// Whether the algorithm is an HMAC, taking a key.
fn keyed(algorithm: Algorithm) bool {
    return switch (algorithm) {
        .hmac_sha256, .hmac_sha384, .hmac_sha512 => true,
        else => false,
    };
}

pub const Digest = struct {
    pub const shape = public.Digest;
    pub const name = shape.name;
    pub const plugins_only = shape.plugins_only;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const verbatim = shape.verbatim;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(chain_max > 0);

        const plugin = http.fetcher_of(ctx) orelse return error.Denied;
        const is_keyed = keyed(in.algorithm);

        if (in.text.len > text_bytes_max or in.chain.len > chain_max) {
            return error.Invalid;
        }

        if (!is_keyed and (in.key.len > 0 or in.chain.len > 0)) {
            return error.Invalid;
        }

        if (is_keyed and in.key.len == 0) {
            return error.Invalid;
        }

        const text = try filled(ctx, plugin, in.text);
        const key = try filled(ctx, plugin, in.key);
        const made = compute(ctx.arena, .{
            .algorithm = in.algorithm,
            .text = text,
            .key = key,
            .chain = in.chain,
            .encoding = in.encoding,
        }) catch return error.OutOfMemory;

        return .{
            .digest = made,
            .matches = in.compare.len > 0 and equal(made, in.compare),
        };
    }
};

/// `text` with the plugin's secrets filled in; each must be declared and set.
fn filled(ctx: *Ctx, plugin: http.Fetcher, text: []const u8) Error![]const u8 {
    std.debug.assert(plugin.name.len > 0);

    var storage: [secrets_max][]const u8 = undefined;
    const names = secrets.names_in(text, &storage) catch return error.Invalid;

    if (names.len == 0) {
        return text;
    }

    const values = try ctx.arena.alloc([]const u8, names.len);

    for (names, values) |secret_name, *value| {
        const declared = secrets.declared_find(plugin.access.secrets, secret_name) orelse {
            return ctx.fail(.{
                .name = "SecretNotDeclared",
                .status = 403,
                .message = "The plugin names a secret it does not declare in .secrets",
            });
        };

        value.* = try secret.value_of(ctx, secret_name) orelse {
            return ctx.fail(.{
                .name = "SecretMissing",
                .status = 409,
                .message = try std.fmt.allocPrint(ctx.arena, "{s} isn't set", .{
                    declared.label,
                }),
            });
        };
    }

    return secrets.fill(ctx.arena, text, names, values) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Invalid,
    };
}

pub const Asked = struct {
    algorithm: Algorithm,
    text: []const u8,
    key: []const u8 = "",
    chain: []const []const u8 = &.{},
    encoding: Encoding = .hex,
};

/// The digest `asked` describes, its secrets already filled in, encoded.
pub fn compute(arena: std.mem.Allocator, asked: Asked) error{OutOfMemory}![]const u8 {
    std.debug.assert(asked.chain.len <= chain_max);

    var raw: [64]u8 = undefined;
    const length: u32 = switch (asked.algorithm) {
        .md5 => plain(hash.Md5, asked.text, &raw),
        .sha1 => plain(hash.Sha1, asked.text, &raw),
        .sha256 => plain(hash.sha2.Sha256, asked.text, &raw),
        .sha384 => plain(hash.sha2.Sha384, asked.text, &raw),
        .sha512 => plain(hash.sha2.Sha512, asked.text, &raw),
        .hmac_sha256 => keyed_by(hmac.sha2.HmacSha256, asked, &raw),
        .hmac_sha384 => keyed_by(hmac.sha2.HmacSha384, asked, &raw),
        .hmac_sha512 => keyed_by(hmac.sha2.HmacSha512, asked, &raw),
    };
    const bytes = raw[0..length];

    std.debug.assert(length > 0 and length <= raw.len);

    return switch (asked.encoding) {
        .hex => try std.fmt.allocPrint(arena, "{x}", .{bytes}),
        .base64 => base64: {
            const encoder = std.base64.standard.Encoder;
            const out = try arena.alloc(u8, encoder.calcSize(bytes.len));

            std.debug.assert(out.len <= digest_bytes_max);

            break :base64 encoder.encode(out, bytes);
        },
    };
}

fn plain(comptime Hash: type, text: []const u8, raw: *[64]u8) u32 {
    std.debug.assert(text.len <= text_bytes_max);
    std.debug.assert(Hash.digest_length <= raw.len);

    var out: [Hash.digest_length]u8 = undefined;

    Hash.hash(text, &out, .{});
    @memcpy(raw[0..out.len], &out);

    return out.len;
}

/// The HMAC of the text under the key, the key first turned by each step of the chain.
fn keyed_by(comptime Hmac: type, asked: Asked, raw: *[64]u8) u32 {
    std.debug.assert(asked.key.len > 0);
    std.debug.assert(Hmac.mac_length <= raw.len);

    var key_buffer: [Hmac.mac_length]u8 = undefined;
    var key: []const u8 = asked.key;

    for (asked.chain) |step| {
        var next: [Hmac.mac_length]u8 = undefined;

        Hmac.create(&next, step, key);
        key_buffer = next;
        key = &key_buffer;
    }

    var out: [Hmac.mac_length]u8 = undefined;

    Hmac.create(&out, asked.text, key);
    @memcpy(raw[0..out.len], &out);
    std.crypto.secureZero(u8, &key_buffer);

    return out.len;
}

/// Whether two signatures are the same, in time that depends only on their lengths; hex is
/// compared case aside.
fn equal(made: []const u8, given: []const u8) bool {
    std.debug.assert(made.len <= digest_bytes_max);

    if (made.len != given.len) {
        return false;
    }

    var differ: u8 = 0;

    for (made, given) |made_byte, given_byte| {
        differ |= std.ascii.toLower(made_byte) ^ std.ascii.toLower(given_byte);
    }

    return differ == 0;
}

test "digests match the published examples" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "900150983cd24fb0d6963f7d28e17f72",
        try compute(arena, .{
            .algorithm = .md5,
            .text = "abc",
        }),
    );
    try std.testing.expectEqualStrings(
        "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed" ++
            "8086072ba1e7cc2358baeca134c825a7",
        try compute(arena, .{
            .algorithm = .sha384,
            .text = "abc",
        }),
    );
    // RFC 4231 test case 2.
    try std.testing.expectEqualStrings(
        "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
        try compute(arena, .{
            .algorithm = .hmac_sha256,
            .text = "what do ya want for nothing?",
            .key = "Jefe",
        }),
    );
    try std.testing.expectEqualStrings(
        "W9zBRr9gdU5qBCQmCJV1x1oAPwidJzmDnexYuWTsOEM=",
        try compute(arena, .{
            .algorithm = .hmac_sha256,
            .text = "what do ya want for nothing?",
            .key = "Jefe",
            .encoding = .base64,
        }),
    );
}

test "a chain turns the key step by step" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Hmac = hmac.sha2.HmacSha256;

    // AWS's signing key, made by hand: HMAC(HMAC("AWS4" + secret, date), region) and on.
    var date: [32]u8 = undefined;
    var region: [32]u8 = undefined;
    var signed: [32]u8 = undefined;

    Hmac.create(&date, "20150830", "AWS4wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY");
    Hmac.create(&region, "us-east-1", &date);
    Hmac.create(&signed, "message", &region);

    try std.testing.expectEqualStrings(
        try std.fmt.allocPrint(arena, "{x}", .{&signed}),
        try compute(arena, .{
            .algorithm = .hmac_sha256,
            .text = "message",
            .key = "AWS4wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            .chain = &.{ "20150830", "us-east-1" },
        }),
    );
}

test "signatures compare case aside, and only at the same length" {
    try std.testing.expect(equal("ab12", "AB12"));
    try std.testing.expect(!equal("ab12", "ab13"));
    try std.testing.expect(!equal("ab12", "ab1"));
}
