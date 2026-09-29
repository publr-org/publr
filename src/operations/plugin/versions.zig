//! A plugin's versions: a newer module waits as its next version until an administrator
//! applies it; applying keeps the version it replaces as the previous one, to roll back to.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const state = @import("state.zig");
const lifecycle = @import("lifecycle.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const sandboxed_plugin = model.sandboxed_plugin;

/// What a version is granted when it takes over: what the plugin held, what enabling
/// grants (low and medium, available, not denied), and (approving) everything it asks for.
pub fn carried(
    arena: std.mem.Allocator,
    asked: []const sandboxed_plugin.Request,
    held: []const []const u8,
    denied: []const []const u8,
    approve_all: bool,
) Error![]const []const u8 {
    std.debug.assert(asked.len <= sandboxed_plugin.requests_max);
    std.debug.assert(held.len <= sandboxed_plugin.requests_max);

    var granted: std.ArrayList([]const u8) = .empty;

    for (asked) |request| {
        const kept = model.permission.contains(held, request.key);
        const refused = model.permission.contains(denied, request.key);
        const fresh = request.available and request.tier != .high and !refused;
        const approved = approve_all and request.available;

        if (kept or fresh or approved) {
            granted.append(arena, request.key) catch return error.OutOfMemory;
        }
    }

    return granted.items;
}

/// Applies the next version: it runs from now, granted everything it asks for (the
/// administrator reviewed it); the version it replaces becomes the previous one.
pub fn update(ctx: *Ctx, name: []const u8) Error!state.Decoded {
    std.debug.assert(name.len > 0);

    const decoded = try state.load(ctx, name);
    const row = decoded.row;
    const hash = row.next_hash orelse return error.NotFound;
    const text = row.next_manifest orelse return error.NotFound;
    var swapped = try take_over(ctx, decoded, hash, text, true);

    swapped.row.previous_version = row.version;
    swapped.row.previous_hash = row.hash;
    swapped.row.previous_manifest = row.manifest;
    swapped.row.next_version = null;
    swapped.row.next_hash = null;
    swapped.row.next_manifest = null;
    try state.save(ctx, swapped);

    return swapped;
}

/// Goes back to the previous version; the one it leaves becomes the previous in turn, so a
/// roll back can itself be undone.
pub fn rollback(ctx: *Ctx, name: []const u8) Error!state.Decoded {
    std.debug.assert(name.len > 0);

    const decoded = try state.load(ctx, name);
    const row = decoded.row;
    const hash = row.previous_hash orelse return error.NotFound;
    const text = row.previous_manifest orelse return error.NotFound;
    var swapped = try take_over(ctx, decoded, hash, text, false);

    swapped.row.previous_version = row.version;
    swapped.row.previous_hash = row.hash;
    swapped.row.previous_manifest = row.manifest;
    try state.save(ctx, swapped);

    return swapped;
}

/// Drops the next version; the current one stays.
pub fn cancel_update(ctx: *Ctx, name: []const u8) Error!state.Decoded {
    std.debug.assert(name.len > 0);

    var decoded = try state.load(ctx, name);

    if (decoded.row.next_hash == null) {
        return error.NotFound;
    }

    decoded.row.next_version = null;
    decoded.row.next_hash = null;
    decoded.row.next_manifest = null;
    try state.save(ctx, decoded);

    return decoded;
}

/// The plugin running `hash` from now: its manifest, its grants carried over, its content
/// types brought up to date when it is enabled. The caller moves the versions around.
fn take_over(
    ctx: *Ctx,
    old: state.Decoded,
    hash: []const u8,
    text: []const u8,
    approve_all: bool,
) Error!state.Decoded {
    std.debug.assert(hash.len > 0);
    std.debug.assert(text.len > 0);

    const manifest = try state.parse_manifest(ctx.arena, text);

    if (!std.mem.eql(u8, manifest.name, old.row.name)) {
        return error.Invalid;
    }

    const asked = try lifecycle.requests(ctx, &manifest);
    var decoded = old;

    if (old.row.enabled) {
        try lifecycle.apply_types(ctx, &manifest);
    }

    decoded.granted = try carried(ctx.arena, asked, old.granted, old.denied, approve_all);
    decoded.manifest = manifest;
    decoded.row.version = manifest.version;
    decoded.row.hash = hash;
    decoded.row.manifest = text;

    return decoded;
}
