//! Where official plugins come from: Publr's plugin server, or the folder or address
//! `PUBLR_PLUGIN_CATALOG` names. It holds `catalog.json` and the built modules it lists.
//! From the web, it is read in queued work only: pages answer the copy the `ai_catalog` job
//! keeps, looked at again when it is an hour old.
//!
//! From the web, a module is installed only when it is the one its version's manifest names
//! (its SHA-256 and size), and that manifest carries the signature of the plugins
//! repository's Publish workflow. A folder is the administrator's own and is read as it is.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const environment = @import("../../lib/environment.zig");
const store = @import("../../store.zig");
const jobs = @import("../job.zig");
const http = @import("../http.zig");
const lifecycle = @import("../plugin/lifecycle.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;

pub const variable = "PUBLR_PLUGIN_CATALOG";
pub const address_default = "https://plugins.publr.app";
const catalog_bytes_max: u32 = 64 << 10;
const manifest_bytes_max: u32 = 4 << 10;
const signature_len = std.crypto.sign.Ed25519.Signature.encoded_length;
/// The public half of the key the plugins repository's Publish workflow signs each version's
/// manifest with (`PLUGINS_SIGNING_KEY`).
pub const signing_key_hex = "c06a33babbbf9b8bd472a9479867f3b5184f33afdb13366d48c5780b4cf4a487";
/// How old a kept catalog may be before it is looked at again; one not reached, a minute.
const fresh_ms: i64 = 60 * 60 * 1000;
const retry_ms: i64 = 60 * 1000;
const kept_key = "plugin.catalog";

pub const Entry = struct {
    name: []const u8,
    label: []const u8,
    summary: []const u8 = "",
    kind: []const u8 = "",
    version: []const u8 = "",
    /// The built module, relative to the catalog.
    module: []const u8 = "",
    /// The plugins it needs installed first, by name.
    requires: []const []const u8 = &.{},
    /// This version's signed manifest, relative to the catalog (`Signed`); its signature is
    /// beside it, in the same name and `.sig`.
    manifest: []const u8 = "",
};

/// What the Publish workflow wrote for one version of a plugin, never rewritten: the module
/// it built, by SHA-256 and size.
pub const Signed = struct {
    name: []const u8,
    version: []const u8,
    module: []const u8,
    /// Hex, lowercase.
    sha256: []const u8,
    size: u32,
};

pub const File = struct {
    plugins: []const Entry = &.{},
};

pub const unreachable_failure: sdk.operation.Failure = .{
    .name = "CatalogUnreachable",
    .status = 502,
    .message = "The list of official plugins could not be reached",
};

const no_module: sdk.operation.Failure = .{
    .name = "NoModule",
    .status = 409,
    .message = "The catalog names no built module for it",
};

const not_signed: sdk.operation.Failure = .{
    .name = "NotSigned",
    .status = 502,
    .message = "The plugin's module is not the one Publr's plugin server signed",
};

/// The folder or address the catalog is read from.
pub fn source() []const u8 {
    std.debug.assert(variable.len > 0);

    const named = environment.get(variable) orelse "";

    return if (named.len == 0) address_default else named;
}

fn on_the_web(from: []const u8) bool {
    std.debug.assert(from.len > 0);

    return std.mem.startsWith(u8, from, "https://") or std.mem.startsWith(u8, from, "http://");
}

/// The catalog as last looked at, in a page's request: read at once from a folder; from the
/// web, the kept copy (`looking` while none is), a look queued when it is old.
pub const Kept = struct {
    at: i64 = 0,
    reached: bool = false,
    plugins: []const Entry = &.{},
    /// A look is on its way and nothing was kept before it.
    looking: bool = false,
    /// The host keeps this server offline: nothing is looked at.
    offline: bool = false,
};

pub fn kept(ctx: *Ctx) Error!Kept {
    std.debug.assert(fresh_ms > retry_ms);

    if (!on_the_web(source())) {
        const file = read(ctx) catch |err| {
            if (err == error.OutOfMemory) {
                return error.OutOfMemory;
            }

            ctx.failure = null;

            return .{};
        };

        return .{
            .at = ctx.now_ms,
            .reached = true,
            .plugins = file.plugins,
        };
    }

    if (ctx.outside.egress == .off) {
        return .{
            .offline = true,
        };
    }

    const text = try store.settings.get(ctx.db, ctx.arena, kept_key);
    var found: Kept = if (text) |json| std.json.parseFromSliceLeaky(Kept, ctx.arena, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch .{} else .{};
    const age_max = if (found.reached) fresh_ms else retry_ms;
    const waiting = try store.job_queue.waiting_for(ctx.db, jobs.core, "ai_catalog");

    if (ctx.now_ms - found.at >= age_max and !waiting) {
        try jobs.enqueue(ctx, "ai_catalog", struct {}{});
    }

    found.looking = text == null;

    return found;
}

/// The `ai_catalog` job: the catalog read from Publr's plugin server and kept; one that
/// cannot be reached is kept as not reached, and looked at again a minute later.
pub fn refresh(ctx: *Ctx, in: struct {}) Error!void {
    std.debug.assert(ctx.job.len > 0);
    std.debug.assert(fresh_ms > retry_ms);

    _ = in;

    const file = read(ctx) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => blk: {
            ctx.failure = null;
            break :blk null;
        },
    };
    const text = std.json.Stringify.valueAlloc(ctx.arena, Kept{
        .at = ctx.now_ms,
        .reached = file != null,
        .plugins = if (file) |found| found.plugins else &.{},
    }, .{}) catch return error.OutOfMemory;

    if (text.len > store.settings.value_len_max) {
        return ctx.fail(unreachable_failure);
    }

    try store.settings.set(ctx.db, kept_key, text, ctx.now_ms);
}

/// The catalog's entries; fails with `unreachable_failure` when it cannot be read. From the
/// web, queued work only.
pub fn read(ctx: *Ctx) Error!File {
    std.debug.assert(catalog_bytes_max > 0);

    const from = source();
    const path = std.fs.path.join(ctx.arena, &.{ from, "catalog.json" }) catch {
        return error.OutOfMemory;
    };
    const text = if (on_the_web(from))
        try fetched_text(ctx, path, catalog_bytes_max)
    else
        std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(catalog_bytes_max)) catch {
            return ctx.fail(unreachable_failure);
        };

    return std.json.parseFromSliceLeaky(File, ctx.arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch ctx.fail(unreachable_failure);
}

/// The entry's module, checked and staged as an upload is. From the web, only the module its
/// version's signed manifest names.
pub fn stage(ctx: *Ctx, entry: Entry) Error!lifecycle.Checked {
    std.debug.assert(entry.name.len > 0);

    if (!inside(entry.module)) {
        return ctx.fail(no_module);
    }

    const from = source();
    const path = std.fs.path.join(ctx.arena, &.{ from, entry.module }) catch {
        return error.OutOfMemory;
    };

    if (!on_the_web(from)) {
        return lifecycle.stage(ctx, path, true);
    }

    if (!inside(entry.manifest)) {
        return ctx.fail(not_signed);
    }

    const manifest_url = std.fs.path.join(ctx.arena, &.{ from, entry.manifest }) catch {
        return error.OutOfMemory;
    };
    const signature_url = std.fmt.allocPrint(ctx.arena, "{s}.sig", .{manifest_url}) catch {
        return error.OutOfMemory;
    };
    const manifest = try fetched_text(ctx, manifest_url, manifest_bytes_max);
    const signature = try fetched_text(ctx, signature_url, signature_len);
    const allocator = std.heap.page_allocator;
    const downloaded = try fetched(ctx, allocator, path, model.sandboxed_plugin.bytes_max);
    defer allocator.free(downloaded.buffer);

    const proven = verified(ctx.arena, .{
        .entry = entry,
        .manifest = manifest,
        .signature = signature,
        .key_hex = signing_key_hex,
        .module = downloaded.bytes,
    }) catch return error.OutOfMemory;

    if (!proven) {
        return ctx.fail(not_signed);
    }

    const file = std.fmt.allocPrint(ctx.arena, "catalog-{s}.wasm", .{entry.name}) catch {
        return error.OutOfMemory;
    };
    const sandboxed = try lifecycle.sandboxed(ctx);

    _ = try sandboxed.receive(file, 0, downloaded.bytes, true);
    defer sandboxed.consume(file);

    return lifecycle.stage(ctx, file, false);
}

/// A path in the catalog: relative, and never above it.
fn inside(path: []const u8) bool {
    return path.len > 0 and path.len <= 256 and !std.fs.path.isAbsolute(path) and
        std.mem.indexOf(u8, path, "..") == null;
}

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

fn fetched_text(ctx: *Ctx, url: []const u8, bytes_max: u32) Error![]const u8 {
    std.debug.assert(url.len > 0);
    std.debug.assert(bytes_max > 0);

    const allocator = std.heap.page_allocator;
    const downloaded = try fetched(ctx, allocator, url, bytes_max);
    defer allocator.free(downloaded.buffer);

    return ctx.arena.dupe(u8, downloaded.bytes) catch error.OutOfMemory;
}

/// What `url` answered with 200, in `allocator`'s memory; any other answer is unreachable.
fn fetched(
    ctx: *Ctx,
    allocator: std.mem.Allocator,
    url: []const u8,
    bytes_max: u32,
) Error!http.Downloaded {
    std.debug.assert(url.len > 0);
    std.debug.assert(bytes_max > 0);

    const downloaded = http.download(ctx, allocator, url, bytes_max) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            ctx.failure = null;
            return ctx.fail(unreachable_failure);
        },
    };

    if (downloaded.status != 200 or downloaded.bytes.len == 0) {
        allocator.free(downloaded.buffer);

        return ctx.fail(unreachable_failure);
    }

    return downloaded;
}

test "the catalog defaults to Publr's plugin server" {
    try std.testing.expect(on_the_web(address_default));
    try std.testing.expect(!on_the_web("/srv/plugins"));
    try std.testing.expect(!on_the_web("plugins"));
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
