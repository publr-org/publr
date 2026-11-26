//! A catalog version's signed manifest: what the plugins repository's Publish workflow wrote
//! for it, and whether a downloaded module is the one it names.

const std = @import("std");
const model = @import("../../../model.zig");
const Entry = @import("../catalog.zig").Entry;

/// What the Publish workflow wrote for one version of a plugin, never rewritten: the module
/// it built, by SHA-256 and size.
pub const Signed = struct {
    name: []const u8,
    version: []const u8,
    module: []const u8,
    /// Hex, lowercase.
    sha256: []const u8,
    size: u32,
    /// The Publr release it was built for; it runs on that release's line.
    publr: []const u8 = "",
};

pub const Proof = struct {
    entry: Entry,
    /// The manifest's bytes, as signed.
    manifest: []const u8,
    signature: []const u8,
    key_hex: []const u8,
    module: []const u8,
};

/// Whether `signature` is the key's over the manifest, the manifest is the entry's version,
/// and `module` is the one it names, byte for byte.
pub fn verified(arena: std.mem.Allocator, proof: Proof) error{OutOfMemory}!bool {
    std.debug.assert(proof.key_hex.len == 64);
    std.debug.assert(proof.entry.name.len > 0);

    if (!model.release.signed(proof.manifest, proof.signature, proof.key_hex)) {
        return false;
    }

    const signed = std.json.parseFromSliceLeaky(Signed, arena, proof.manifest, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    const named = std.mem.eql(u8, signed.name, proof.entry.name) and
        std.mem.eql(u8, signed.version, proof.entry.version) and
        std.mem.eql(u8, signed.module, proof.entry.module);

    if (!named or signed.size != proof.module.len) {
        return false;
    }

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(proof.module, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);

    return std.mem.eql(u8, &hex, signed.sha256);
}

test "a module from the web installs only as its signed manifest names it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const Ed25519 = std.crypto.sign.Ed25519;
    const keys = try Ed25519.KeyPair.generateDeterministic(@splat(7));
    const other = try Ed25519.KeyPair.generateDeterministic(@splat(8));
    const key_hex = std.fmt.bytesToHex(keys.public_key.toBytes(), .lower);
    const module = "\x00asm\x01\x00\x00\x00";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(module, &digest, .{});
    const manifest = try std.fmt.allocPrint(
        arena,
        "{{\"name\":\"blog\",\"version\":\"0.2.1\",\"module\":\"dist/blog/0.2.1.wasm\"," ++
            "\"sha256\":\"{s}\",\"size\":{d}}}",
        .{ &std.fmt.bytesToHex(digest, .lower), module.len },
    );
    const signature = (try keys.sign(manifest, null)).toBytes();
    const entry: Entry = .{
        .name = "blog",
        .label = "Blog",
        .version = "0.2.1",
        .module = "dist/blog/0.2.1.wasm",
        .manifest = "dist/blog/0.2.1.json",
    };
    const proof: Proof = .{
        .entry = entry,
        .manifest = manifest,
        .signature = &signature,
        .key_hex = &key_hex,
        .module = module,
    };

    try std.testing.expect(try verified(arena, proof));

    var changed = proof;
    changed.module = "\x00asm\x01\x00\x00\x01";
    try std.testing.expect(!try verified(arena, changed));

    const forged = (try other.sign(manifest, null)).toBytes();
    changed = proof;
    changed.signature = &forged;
    try std.testing.expect(!try verified(arena, changed));

    changed = proof;
    changed.manifest = try std.mem.replaceOwned(u8, arena, manifest, "\"size\":8", "\"size\":9");
    try std.testing.expect(!try verified(arena, changed));

    changed = proof;
    changed.entry.version = "0.2.0";
    try std.testing.expect(!try verified(arena, changed));
}
