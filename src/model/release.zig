//! Publr's releases as an update sees them: which kind one is from another, which file is
//! this machine's, and whether a release's checksums are the ones Publr signed.

const std = @import("std");
const builtin = @import("builtin");

/// The public half of the key the Release workflow signs `SHA256SUMS` with
/// (`PUBLR_RELEASE_SIGNING_KEY`). A checksum from the same page as the file proves nothing
/// alone; this signature is what an update trusts.
pub const signing_key_hex = "72928f861218c31c9358d8be4d51294e4fe923a2970d784740f436e28a7567e8";
pub const repository = "publr-org/publr";
pub const notes_bytes_max: u32 = 4096;
pub const releases_max: u32 = 100;

/// What an update from one release to another does to a site (`updates.md`): a patch only
/// swaps the binary, a minor runs a migration that only adds, a major may need care.
pub const Kind = enum { patch, minor, major };

pub const Release = struct {
    version: []const u8,
    kind: Kind,
    /// The release notes, cut at `notes_bytes_max`.
    notes: []const u8,
    published_at: []const u8,
    url: []const u8,
};

pub fn kind_between(from: []const u8, to: []const u8) !Kind {
    std.debug.assert(from.len > 0);
    std.debug.assert(to.len > 0);

    const before = try std.SemanticVersion.parse(from);
    const after = try std.SemanticVersion.parse(to);

    if (after.major != before.major) {
        return .major;
    }

    return if (after.minor != before.minor) .minor else .patch;
}

pub fn newer(from: []const u8, to: []const u8) bool {
    std.debug.assert(from.len > 0);

    const before = std.SemanticVersion.parse(from) catch return false;
    const after = std.SemanticVersion.parse(to) catch return false;

    return after.order(before) == .gt;
}

/// This machine's file in a release: `publr-macos-aarch64`, `publr-linux-x86_64`.
pub fn asset_name() []const u8 {
    const os = switch (builtin.os.tag) {
        .macos => "macos",
        .linux => "linux",
        else => "unsupported",
    };
    const arch = switch (builtin.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => "unsupported",
    };
    const name = "publr-" ++ os ++ "-" ++ arch;

    comptime std.debug.assert(name.len > "publr-".len);

    return name;
}

/// The SHA-256 `sums` (a `SHA256SUMS` file) gives for `file`, as hex.
pub fn sum_of(sums: []const u8, file: []const u8) ?[]const u8 {
    std.debug.assert(file.len > 0);

    var lines = std.mem.tokenizeScalar(u8, sums, '\n');

    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " *");
        const digest = words.next() orelse continue;
        const name = words.next() orelse continue;

        if (std.mem.eql(u8, name, file) and digest.len == 64) {
            return digest;
        }
    }

    return null;
}

/// Whether `signature` is Publr's (the key whose public half is `key_hex`) over `sums`.
pub fn signed(sums: []const u8, signature: []const u8, key_hex: []const u8) bool {
    std.debug.assert(key_hex.len == 64);

    if (signature.len != std.crypto.sign.Ed25519.Signature.encoded_length) {
        return false;
    }

    var key_bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&key_bytes, key_hex) catch return false;
    const key = std.crypto.sign.Ed25519.PublicKey.fromBytes(key_bytes) catch return false;
    const parsed = std.crypto.sign.Ed25519.Signature.fromBytes(signature[0..64].*);

    parsed.verify(sums, key) catch return false;

    return true;
}

/// The releases in GitHub's list (`/repos/<repository>/releases`) newer than `current`,
/// newest first. Drafts, prereleases and tags that are not versions are left out.
pub fn newer_in(
    arena: std.mem.Allocator,
    listing: []const u8,
    current: []const u8,
) ![]const Release {
    std.debug.assert(current.len > 0);

    const Listed = struct {
        tag_name: []const u8,
        body: ?[]const u8 = null,
        published_at: ?[]const u8 = null,
        html_url: []const u8 = "",
        draft: bool = false,
        prerelease: bool = false,
    };
    const listed = try std.json.parseFromSliceLeaky([]const Listed, arena, listing, .{
        .ignore_unknown_fields = true,
    });
    var releases: std.ArrayList(Release) = .empty;

    for (listed[0..@min(listed.len, releases_max)]) |item| {
        const version = if (std.mem.startsWith(u8, item.tag_name, "v")) item.tag_name[1..] else "";

        if (item.draft or item.prerelease or !newer(current, version)) {
            continue;
        }

        const notes = item.body orelse "";

        try releases.append(arena, .{
            .version = version,
            .kind = try kind_between(current, version),
            .notes = notes[0..@min(notes.len, notes_bytes_max)],
            .published_at = item.published_at orelse "",
            .url = item.html_url,
        });
    }

    std.mem.sort(Release, releases.items, {}, newest_first);

    return releases.items;
}

fn newest_first(_: void, left: Release, right: Release) bool {
    std.debug.assert(left.version.len > 0);

    return newer(right.version, left.version);
}

test "the kind of an update is the part of the version that moved" {
    try std.testing.expectEqual(Kind.patch, try kind_between("0.3.0", "0.3.4"));
    try std.testing.expectEqual(Kind.minor, try kind_between("0.3.4", "0.5.0"));
    try std.testing.expectEqual(Kind.major, try kind_between("0.9.1", "1.0.0"));
    try std.testing.expect(newer("0.3.9", "0.10.0"));
    try std.testing.expect(!newer("0.3.0", "0.3.0"));
    try std.testing.expect(!newer("0.3.0", "nope"));
}

test "a checksum is found by its file's name" {
    const sums = "abc  publr-linux-x86_64\n" ++ ("d" ** 64) ++ "  publr-macos-aarch64\n";

    try std.testing.expectEqualStrings("d" ** 64, sum_of(sums, "publr-macos-aarch64").?);
    try std.testing.expect(sum_of(sums, "publr-linux-x86_64") == null);
    try std.testing.expect(sum_of(sums, "install.sh") == null);
}

test "a signature made by openssl with the key's private half is accepted, nothing else" {
    // `openssl pkeyutl -sign -rawin` with a throwaway key, as the Release workflow signs.
    const key = "2138d78a3d26633bf1f0ca6d2a2cafa98f6272c278cba4129fb41e0b8e4362e1";
    const sums = "abc123  publr-linux-x86_64\ndef456  install.sh\n";
    const signature_hex = "586c091e6e7ac6ad0c90d0350ebf09c734164fb190ff3f8a85158a400467ddce" ++
        "d67a94944ebdc8586af865422f27faf266e77b748dec61f5e38d4fbc72096505";
    var signature: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&signature, signature_hex);

    try std.testing.expect(signed(sums, &signature, key));
    try std.testing.expect(!signed(sums ++ "x", &signature, key));
    try std.testing.expect(!signed(sums, &signature, signing_key_hex));
    try std.testing.expect(!signed(sums, signature[0..63], key));
}

test "newer releases are listed newest first, with their kind" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const listing =
        \\[{"tag_name":"v0.4.0","body":"Adds","published_at":"2026-11-01"},
        \\ {"tag_name":"v0.3.2","body":"Fixes"},
        \\ {"tag_name":"v0.3.1","draft":true},
        \\ {"tag_name":"v0.3.0"},
        \\ {"tag_name":"v1.0.0-rc.1","prerelease":true}]
    ;
    const found = try newer_in(arena_state.allocator(), listing, "0.3.0");

    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings("0.4.0", found[0].version);
    try std.testing.expectEqual(Kind.minor, found[0].kind);
    try std.testing.expectEqual(Kind.patch, found[1].kind);
}
