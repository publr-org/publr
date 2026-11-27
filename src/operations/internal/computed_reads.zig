//! What a computed field's work read and what it was made under: the keys, gathered as the
//! work reads, the time its answer holds until, and the stamp of the code and modifiers
//! that made it. `computed.zig` notes them in `lib/deps` with the value.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const computed = @import("computed.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const Collection = model.internal_record.Collection;
const Scope = store.internal_records.Scope;
const SDK = registry.SDK;
/// The release running: the code of every plugin compiled into it.
const release = @import("../../publr/version.zig").version;

/// The most keys one batch's work may read and still be noted; past it the values are kept
/// but never fresh, so each read works them out again.
pub const keys_max: u32 = 512;
/// The bytes those keys may take.
const key_bytes_max: u32 = 32 << 10;

/// What one batch's work read: each key once, handed on to a page being built around it.
/// Its memory is taken whole before the work starts: the plugin's calls give back what they
/// took after it, and a key kept there would be written over.
pub const Noted = struct {
    outer: ?sdk.Reads,
    text: []u8,
    used: u32 = 0,
    keys: [][]const u8,
    len: u32 = 0,
    seen: std.StringHashMapUnmanaged(void),
    complete: bool = true,
    /// The earliest time the work said its answer holds until (`ctx.holds_until`).
    until_ms: ?i64 = null,

    pub fn init(arena: std.mem.Allocator, outer: ?sdk.Reads) Error!Noted {
        std.debug.assert(keys_max > 0);
        std.debug.assert(key_bytes_max > 0);

        var seen: std.StringHashMapUnmanaged(void) = .empty;

        seen.ensureTotalCapacity(arena, keys_max) catch return error.OutOfMemory;

        return .{
            .outer = outer,
            .text = arena.alloc(u8, key_bytes_max) catch return error.OutOfMemory,
            .keys = arena.alloc([]const u8, keys_max) catch return error.OutOfMemory,
            .seen = seen,
        };
    }

    /// Empty again, for the next batch: its memory stays.
    pub fn reset(noted: *Noted) void {
        std.debug.assert(noted.len <= keys_max);
        std.debug.assert(noted.text.len == key_bytes_max);

        noted.len = 0;
        noted.used = 0;
        noted.seen.clearRetainingCapacity();
        noted.complete = true;
        noted.until_ms = null;
    }

    pub fn noted_keys(noted: *const Noted) []const []const u8 {
        std.debug.assert(noted.len <= keys_max);
        std.debug.assert(noted.used <= key_bytes_max);

        return noted.keys[0..noted.len];
    }

    pub fn reads(noted: *Noted) sdk.Reads {
        std.debug.assert(noted.len <= keys_max);
        std.debug.assert(noted.seen.count() == noted.len);

        return .{
            .context = noted,
            .read = read,
        };
    }

    fn read(context: *anyopaque, key: []const u8) void {
        const noted: *Noted = @ptrCast(@alignCast(context));

        std.debug.assert(key.len > 0);
        std.debug.assert(noted.len <= keys_max);

        if (until_of(key)) |until| {
            noted.until_ms = @min(noted.until_ms orelse until, until);
            return;
        }

        if (noted.outer) |outer| {
            outer.read(outer.context, key);
        }

        if (noted.seen.contains(key)) {
            return;
        }

        if (noted.len == keys_max or noted.used + key.len > noted.text.len) {
            noted.complete = false;
            return;
        }

        const kept = noted.text[noted.used..][0..key.len];

        @memcpy(kept, key);
        noted.used += @intCast(key.len);
        noted.keys[noted.len] = kept;
        noted.len += 1;
        noted.seen.putAssumeCapacity(kept, {});
    }
};

/// What `internal.holds_until` names as read while a value is worked out: `until:<ms>`. Never
/// a key a write raises; the work's answer stops holding then.
pub const until_prefix = "until:";

fn until_of(key: []const u8) ?i64 {
    std.debug.assert(key.len > 0);
    std.debug.assert(until_prefix.len > 0);

    if (!std.mem.startsWith(u8, key, until_prefix)) {
        return null;
    }

    return std.fmt.parseInt(i64, key[until_prefix.len..], 10) catch null;
}

/// What each computed field of the collection is worked out under: the code of the plugins
/// that work it out and change it (the release compiled in, each installed one's version)
/// and which modifiers those are. One installed, removed or updated makes every value of
/// the field stale.
pub fn stamps_of(ctx: *Ctx, scope: Scope, collection: Collection) Error![]const u64 {
    std.debug.assert(collection.computed.len > 0);
    std.debug.assert(collection.computed.len <= model.internal_record.computed_max);

    const stamps = ctx.arena.alloc(u64, collection.computed.len) catch return error.OutOfMemory;
    const modifiers = try SDK.modifiers(ctx);

    for (collection.computed, stamps) |field, *stamp| {
        var buffer: [computed.name_len_max]u8 = undefined;
        const record = try computed.record_name(&buffer, scope, field);
        var hasher = std.hash.Wyhash.init(0);

        hasher.update(release);

        for (modifiers) |modifier| {
            const own = std.mem.startsWith(u8, modifier.name, "computed.") and
                std.mem.eql(u8, modifier.name["computed.".len..], record);

            if (!own and !sdk.mods.matches(modifier.name, record)) {
                continue;
            }

            hasher.update(modifier.plugin);
            hasher.update(modifier.name);
            hasher.update(installed_version(ctx, modifier.plugin));
        }

        stamp.* = hasher.final();
    }

    return stamps;
}

/// An installed plugin's version; empty for one compiled in, whose code is the release's.
fn installed_version(ctx: *const Ctx, plugin: []const u8) []const u8 {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    const sandboxed = ctx.sandboxed_plugins orelse return "";

    for (sandboxed.manifests()) |manifest| {
        if (std.mem.eql(u8, manifest.name, plugin)) {
            return manifest.version;
        }
    }

    return "";
}

test "a time the work's answer holds until" {
    try std.testing.expectEqual(@as(?i64, 1700), until_of("until:1700"));
    try std.testing.expectEqual(@as(?i64, null), until_of("internal:sampler/tally"));
    try std.testing.expectEqual(@as(?i64, null), until_of("until:soon"));
}
