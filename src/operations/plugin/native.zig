//! A built-in plugin read as an installed one is: its manifest, generated from its declarations
//! as an installed build writes it, and every request granted, since a build grants what a
//! plugin compiled in asks for. Nothing is stored: only a new build changes it.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const state = @import("state.zig");
const registry = @import("../../server/registry.zig");
const plugin_manifest = @import("../../sdk/plugin/manifest.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const permission = model.permission;

/// The built-in plugin called `name`, or the installed one; not found for neither.
pub fn load(ctx: *Ctx, name: []const u8) Error!state.Decoded {
    std.debug.assert(name.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    return try find(ctx, name) orelse state.load(ctx, name);
}

/// The built-in plugin called `name`; null when none is compiled in.
pub fn find(ctx: *Ctx, name: []const u8) Error!?state.Decoded {
    std.debug.assert(name.len > 0);

    inline for (registry.native_plugins.all) |Plugin| {
        if (std.mem.eql(u8, Plugin.manifest.name, name)) {
            return try decoded_of(ctx, comptime plugin_manifest.of(Plugin));
        }
    }

    return null;
}

fn decoded_of(ctx: *Ctx, manifest: model.sandboxed_plugin.Manifest) Error!state.Decoded {
    std.debug.assert(manifest.name.len > 0);

    const asked = model.sandboxed_plugin.requests(&permission.core, &manifest, ctx.arena) catch {
        return error.Invalid;
    };
    const granted = try ctx.arena.alloc([]const u8, asked.len);
    var grants: std.ArrayList(permission.Held) = .empty;

    std.debug.assert(asked.len <= model.sandboxed_plugin.requests_max);

    for (asked, granted) |request, *key| {
        key.* = request.key;

        if (request.asked) |held| {
            try grants.append(ctx.arena, held);
        }
    }

    return .{
        .row = row_of(manifest),
        .manifest = manifest,
        .granted = granted,
        .denied = &.{},
        .grants = grants.items,
        .mode = .native,
    };
}

/// What the plugin's page reads of a row, for one no table holds: running, no versions
/// waiting or behind it.
fn row_of(manifest: model.sandboxed_plugin.Manifest) store.sandboxed_plugins.Row {
    std.debug.assert(manifest.name.len > 0);
    std.debug.assert(manifest.version.len > 0);

    return .{
        .name = manifest.name,
        .version = manifest.version,
        .hash = "",
        .manifest = "",
        .enabled = true,
        .granted = "[]",
        .denied = "[]",
        .grants = "[]",
        .next_version = null,
        .next_hash = null,
        .next_manifest = null,
        .previous_version = null,
        .previous_hash = null,
        .previous_manifest = null,
        .installed_at = 0,
        .updated_at = 0,
    };
}

test "a built-in plugin reads as running, every request granted; an unknown one is not found" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.system);

    try std.testing.expectError(error.NotFound, load(&ctx, "nobody-here"));

    if (registry.native_plugins.all.len == 0) {
        return error.SkipZigTest;
    }

    const name = registry.native_plugins.all[0].manifest.name;
    const decoded = try load(&ctx, name);

    try std.testing.expectEqual(.native, decoded.mode);
    try std.testing.expect(decoded.row.enabled);
    try std.testing.expectEqualStrings(name, decoded.manifest.name);
    try std.testing.expect(decoded.granted.len >= decoded.manifest.permissions.len);
    try std.testing.expectEqual(@as(usize, 0), decoded.denied.len);

    for (decoded.manifest.permissions) |ask| {
        try std.testing.expect(permission.contains(decoded.granted, ask.key));
    }
}
