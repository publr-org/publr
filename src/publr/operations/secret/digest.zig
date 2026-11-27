//! `secret.digest`: a hash of text that holds a plugin's secrets, made by core so the plugin
//! never holds them. What a gateway's signature is (Przelewy24's `sha384` over a JSON with
//! its CRC key, PayU's `md5(body + key)`, an HMAC keyed with an API secret, AWS's chained
//! HMAC key), answered as hex or base64, and compared with a signature the plugin was sent
//! in constant time.
const operation = @import("../../operation.zig");

/// The most text a digest is made of: a webhook's body fits.
pub const text_bytes_max: u32 = 1 << 20;
/// The most steps a key's chain takes: AWS takes four.
pub const chain_max: u32 = 8;

pub const Algorithm = enum {
    md5,
    sha1,
    sha256,
    sha384,
    sha512,
    hmac_sha256,
    hmac_sha384,
    hmac_sha512,
};

pub const Encoding = enum { hex, base64 };

pub const Digest = struct {
    pub const name = "secret.digest";
    /// A plugin's alone: not listed among the commands people and agents run.
    pub const plugins_only = true;
    pub const description = "Hash text holding the plugin's secrets, as the plugin";
    pub const details =
        \\The digest of `text` with each `{secret:NAME}` in it (and in `key`) filled in by
        \\core: the plugin never holds the value. A plain hash (`md5`, `sha1`, `sha256`,
        \\`sha384`, `sha512`) of the text, or an HMAC (`hmac_sha256`, `hmac_sha384`,
        \\`hmac_sha512`) of it keyed with `key`; each step of `chain` first turns the key into
        \\the HMAC of that step under it (AWS's signing key), and the key made along the way
        \\never leaves core. Answered as hex (lower case) or base64. With `compare`, a
        \\signature the plugin was sent, `matches` says whether it is the digest, compared in
        \\constant time. Refused unless the caller is a plugin's code, and every secret named
        \\is declared in its `.secrets` and set.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        algorithm: Algorithm,
        text: []const u8,
        key: []const u8 = "",
        chain: []const []const u8 = &.{},
        encoding: Encoding = .hex,
        compare: []const u8 = "",
    };
    pub const Out = struct {
        digest: []const u8,
        matches: bool = false,
    };
    /// Text a gateway signs and a signature it sent: neither is read as anything here.
    pub const verbatim = .{ "text", "compare" };
    pub const example: In = .{
        .algorithm = .sha384,
        .text = "{\"sessionId\":\"a1b2\",\"merchantId\":11111,\"amount\":1250," ++
            "\"currency\":\"PLN\",\"crc\":\"{secret:P24_CRC}\"}",
    };
    pub const example_out: Out = .{
        .digest = "9c0b8a…",
    };
    pub const field_docs: operation.Docs(In) = .{
        .algorithm = "md5, sha1, sha256, sha384, sha512, hmac_sha256, hmac_sha384 or " ++
            "hmac_sha512",
        .text = "What is hashed, up to 1 MiB; may hold {secret:NAME}",
        .key = "An HMAC's key; may hold {secret:NAME}. Only for the hmac_ algorithms",
        .chain = "Up to 8 steps, each turning the key into HMAC(key, step) first",
        .encoding = "hex (lower case) or base64",
        .compare = "A signature to check against the digest, in the same encoding",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .digest = "The digest, in the encoding asked for",
        .matches = "Whether `compare` is the digest; false when none was given",
    };
};
