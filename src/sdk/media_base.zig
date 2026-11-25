//! Where every media address Publr writes starts: the mod `media.base`
//! (`publr.modify("media.base", …)`, the value `{ "base": "" }`). Empty, as nobody changes
//! it, is the site's own address: `/media/<key>`, under the path the project is served
//! at. A plugin that answers an origin (`https://media.example.com`, a path under it at
//! most) sends browsers there for every file, resized copies too. Nothing else uses it.

const std = @import("std");
const sdk = @import("../sdk.zig");
const registry = @import("../server/registry.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;

pub const mod_name = "media.base";
/// The key a page that writes media addresses depends on: raised by `mod.changed` when the
/// plugin answering the mod says its base changed.
pub const dependency_key = "mod:" ++ mod_name;
pub const prefix = "/media/";
const base_len_max: u32 = 512;

/// The value the mod passes: empty, the site's own address, until a plugin answers another.
pub const Applied = struct {
    base: []const u8 = "",
};

/// The base this call's media addresses start with; empty for the site's own. An answer
/// that is not an http(s) address without a query or a fragment is left out.
pub fn of(ctx: *Ctx) Error![]const u8 {
    std.debug.assert(ctx.now_ms >= 0);

    if (ctx.media_base) |read| {
        return read;
    }

    if (!registry.SDK.modified(ctx, mod_name)) {
        return "";
    }

    // A typed value, held laid out through the modifiers: no text is written for it.
    const made = registry.SDK.modify_all(ctx, mod_name, Applied, &.{.{}}) catch |err| {
        return if (err == error.Invalid) "" else err;
    };
    const answered = if (made.len == 1) valid(made[0].base) else "";
    // Kept for the rest of the call only in memory that lasts it.
    const lasting = ctx.kept_memory();
    const kept = try (lasting orelse ctx.arena).dupe(u8, answered);

    if (lasting != null) {
        ctx.media_base = kept;
    }

    std.debug.assert(kept.len <= base_len_max);

    return kept;
}

/// Where the file under `key` is served: `/media/<key>`, or under the base a plugin gave.
pub fn url(ctx: *Ctx, key: []const u8) Error![]const u8 {
    std.debug.assert(key.len > 0);
    std.debug.assert(key[0] != '/');

    return under(ctx.arena, try of(ctx), key);
}

/// `base` + `/media/` + `key`.
pub fn under(arena: std.mem.Allocator, base: []const u8, key: []const u8) Error![]const u8 {
    std.debug.assert(key.len > 0);
    std.debug.assert(base.len <= base_len_max);

    return std.mem.concat(arena, u8, &.{ base, prefix, key }) catch error.OutOfMemory;
}

/// `answer` as a base, its trailing `/` left off; empty when it cannot be one.
pub fn valid(answer: []const u8) []const u8 {
    const base = std.mem.trimEnd(u8, answer, "/");
    const rest = std.mem.cutPrefix(u8, base, "https://") orelse
        std.mem.cutPrefix(u8, base, "http://") orelse return "";

    if (base.len > base_len_max or rest.len == 0 or rest[0] == '/') {
        return "";
    }

    for (rest) |char| {
        const refused = char <= ' ' or char >= 0x7f or
            std.mem.indexOfScalar(u8, "\"'<>?#\\@`", char) != null;

        if (refused) {
            return "";
        }
    }

    std.debug.assert(base.len > rest.len);

    return base;
}

test "valid: an http(s) origin, a path under it at most" {
    const cloud = "https://ababa.publr.app";

    try std.testing.expectEqualStrings(cloud, valid(cloud));
    try std.testing.expectEqualStrings(cloud, valid(cloud ++ "/"));
    try std.testing.expectEqualStrings("http://cdn.test/site", valid("http://cdn.test/site"));
    try std.testing.expectEqualStrings("", valid(""));
    try std.testing.expectEqualStrings("", valid("/media"));
    try std.testing.expectEqualStrings("", valid("//cdn.test"));
    try std.testing.expectEqualStrings("", valid("ftp://cdn.test"));
    try std.testing.expectEqualStrings("", valid("https://"));
    try std.testing.expectEqualStrings("", valid("https:///a"));
    try std.testing.expectEqualStrings("", valid(cloud ++ "?a=1"));
    try std.testing.expectEqualStrings("", valid(cloud ++ "#a"));
    try std.testing.expectEqualStrings("", valid("https://a\"b.test"));
    try std.testing.expectEqualStrings("", valid("https://a b.test"));
    try std.testing.expectEqualStrings("", valid("https://ada@cdn.test"));
}

test "nobody changes the base: addresses are the site's own" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var system = harness.ctx(.system);

    try std.testing.expectEqualStrings("", try of(&system));
    const cake = try url(&system, "2026/11/cake.webp");

    try std.testing.expectEqualStrings("/media/2026/11/cake.webp", cake);
    try std.testing.expectEqualStrings(
        "https://cdn.test/media/a.png",
        try under(system.arena, "https://cdn.test", "a.png"),
    );
}
