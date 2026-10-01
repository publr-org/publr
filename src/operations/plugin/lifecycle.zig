//! Adding, enabling, disabling and removing a plugin: what is checked before a module
//! is taken, what enabling grants, and what removing leaves. Versions are `versions.zig`.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const registry = @import("../../server/registry.zig");
const state = @import("state.zig");
const plugin_types = @import("../../sdk/plugin/types.zig");
const types = @import("../content_type.zig");
const versions = @import("versions.zig");
const requires = @import("../../sdk/plugin/requires.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const sandboxed_plugin = model.sandboxed_plugin;

/// Core's namespaces, which no plugin may take for its own.
const core_namespaces = [_][]const u8{
    "heartbeat", "project",  "custom_fields", "user",     "sign_on", "identity", "status",
    "role",      "record",   "content_type",  "taxonomy", "term",    "snapshot", "view",
    "plugin",    "settings",
};

pub fn sandboxed(ctx: *Ctx) Error!*const sdk.sandboxed_plugins.SandboxedPlugins {
    std.debug.assert(ctx.now_ms >= 0);

    return ctx.sandboxed_plugins orelse error.Unavailable;
}

/// A module whose manifest passed the checks.
pub const Checked = struct {
    staged: sdk.sandboxed_plugins.Staged,
    manifest: sandboxed_plugin.Manifest,
};

/// Reads and checks a module and its manifest: an upload by its name, or (`anywhere`, the
/// local operator) any path.
pub fn stage(ctx: *Ctx, file: []const u8, anywhere: bool) Error!Checked {
    std.debug.assert(ctx.now_ms >= 0);

    if (file.len == 0 or file.len > 4096) {
        return error.Invalid;
    }

    const staged = try (try sandboxed(ctx)).stage(ctx.arena, file, anywhere);
    const manifest = try state.parse_manifest(ctx.arena, staged.manifest);

    try check(ctx, &manifest);

    return .{ .staged = staged, .manifest = manifest };
}

/// What a manifest must hold to be installed at all, whatever an administrator grants.
fn check(ctx: *Ctx, manifest: *const sandboxed_plugin.Manifest) Error!void {
    std.debug.assert(manifest.format == sandboxed_plugin.format);

    const name = manifest.name;

    if (!sandboxed_plugin.valid_name(name) or manifest.version.len == 0) {
        return error.Invalid;
    }

    if (manifest.version.len > sandboxed_plugin.version_len_max or taken(name)) {
        return error.Invalid;
    }

    for (manifest.operations) |operation| {
        if (operation.name.len > sdk.operation.name_len_max or
            std.mem.indexOfScalar(u8, operation.name, '.') == null or
            !sdk.plugin_access.own(name, operation.name))
        {
            return error.Invalid;
        }
    }

    if (sandboxed_plugin.role_problem(name, manifest.roles) != null) {
        return error.Invalid;
    }

    std.debug.assert(ctx.now_ms >= 0);
}

/// Whether a name is core's or a native plugin's: a plugin cannot take it.
fn taken(name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (core_namespaces) |namespace| {
        if (std.mem.eql(u8, namespace, name)) {
            return true;
        }
    }

    inline for (registry.native_plugins.all) |Plugin| {
        if (std.mem.eql(u8, Plugin.manifest.name, name)) {
            return true;
        }
    }

    return false;
}

/// Whether a plugin or a native plugin called `name` is there.
fn provided(ctx: *Ctx, text: []const u8) bool {
    std.debug.assert(text.len > 0);

    const wanted = requires.parse(text);
    const name = wanted.name;

    inline for (registry.native_plugins.all) |Plugin| {
        if (std.mem.eql(u8, Plugin.manifest.name, name)) {
            return requires.satisfies(Plugin.manifest.version, wanted.range);
        }
    }

    if (!sandboxed_plugin.valid_name(name)) {
        return false;
    }

    const found = store.sandboxed_plugins.get(ctx.db, ctx.arena, name) catch return false;
    const row = found orelse return false;

    return requires.satisfies(row.version, wanted.range);
}

/// Creates or brings up to date the content types and custom fields the plugin declares,
/// as the system: owned by the plugin, their declared fields locked.
pub fn apply_types(ctx: *Ctx, manifest: *const sandboxed_plugin.Manifest) Error!void {
    std.debug.assert(manifest.name.len > 0);
    std.debug.assert(manifest.content_types.len <= 64);

    for (manifest.content_types) |def| {
        if (try types.find_raw(ctx, def.handle)) |existing| {
            if (!std.mem.eql(u8, existing.def.owner, manifest.name)) {
                return error.Conflict;
            }
        }
    }

    const saved = ctx.caller;

    ctx.caller = .system;
    defer ctx.caller = saved;

    for (manifest.content_types) |def| {
        try plugin_types.apply_one(ctx, .{ .owner = manifest.name, .def = def });
    }

    for (manifest.custom_fields) |def| {
        try plugin_types.apply_group(ctx, .{ .owner = manifest.name, .def = def });
    }
}

/// What adding a module did: a plugin new to the list, or a newer version of one there.
pub const Added = struct { name: []const u8, version: []const u8, update: bool };

/// Adds a checked module to the list: a new plugin, disabled; or, for a plugin there
/// already, its next version, waiting to be applied. Nothing runs yet.
pub fn add(ctx: *Ctx, checked: Checked) Error!Added {
    std.debug.assert(checked.staged.hash.len > 0);

    const manifest = checked.manifest;
    const added: Added = .{ .name = manifest.name, .version = manifest.version, .update = false };

    if (try store.sandboxed_plugins.get(ctx.db, ctx.arena, manifest.name)) |row| {
        var decoded = try state.decode(ctx.arena, row);

        if (std.mem.eql(u8, row.hash, checked.staged.hash)) {
            return error.Conflict;
        }

        decoded.row.next_version = manifest.version;
        decoded.row.next_hash = checked.staged.hash;
        decoded.row.next_manifest = checked.staged.manifest;
        try state.save(ctx, decoded);
        ctx.notice("plugin.update_added", added.name);

        return .{ .name = added.name, .version = added.version, .update = true };
    }

    if (try store.sandboxed_plugins.count(ctx.db) >= sandboxed_plugin.sandboxed_plugins_max) {
        return error.Invalid;
    }

    try state.save(ctx, .{
        .row = .{
            .name = manifest.name,
            .version = manifest.version,
            .hash = checked.staged.hash,
            .manifest = checked.staged.manifest,
            .enabled = false,
            .granted = "[]",
            .denied = "[]",
            .content_access = "{}",
            .next_version = null,
            .next_hash = null,
            .next_manifest = null,
            .previous_version = null,
            .previous_hash = null,
            .previous_manifest = null,
            .installed_at = ctx.now_ms,
            .updated_at = ctx.now_ms,
        },
        .manifest = manifest,
        .granted = &.{},
        .denied = &.{},
        .content_access = .{ .scope = manifest.content_access.recommend },
    });
    ctx.notice("plugin.added", added.name);

    return added;
}

/// Starts it: the plugins it requires must be there, its content types are created, and
/// it is granted what enabling grants (see `versions.carried`), with the content access
/// chosen. A plugin disabled before keeps what it held.
pub fn enable(ctx: *Ctx, name: []const u8, access: state.ContentAccess) Error!state.Decoded {
    std.debug.assert(name.len > 0);

    var decoded = try state.load(ctx, name);

    for (decoded.manifest.requires) |required| {
        if (!provided(ctx, required)) {
            return error.Invalid;
        }
    }

    try apply_types(ctx, &decoded.manifest);

    const asked = try requests(ctx, &decoded.manifest);

    const held = decoded.granted;

    decoded.granted = try versions.carried(ctx.arena, asked, held, decoded.denied, false);
    decoded.content_access = access;
    decoded.row.enabled = true;
    try state.save(ctx, decoded);

    return decoded;
}

/// Stops it: its operations and hooks unload; its grants, content types and records stay.
pub fn disable(ctx: *Ctx, name: []const u8) Error!state.Decoded {
    std.debug.assert(name.len > 0);

    var decoded = try state.load(ctx, name);

    decoded.row.enabled = false;
    try state.save(ctx, decoded);

    return decoded;
}

pub fn requests(
    ctx: *Ctx,
    manifest: *const sandboxed_plugin.Manifest,
) Error![]const sandboxed_plugin.Request {
    std.debug.assert(manifest.name.len > 0);

    const catalog = &model.permission.core;

    return sandboxed_plugin.requests(catalog, manifest, ctx.arena) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Invalid => error.Invalid,
    };
}

/// Takes it off the list: unloaded, its grants and versions dropped; its content types and
/// records stay until an administrator deletes them. Its files go at the next reload.
pub fn remove(ctx: *Ctx, name: []const u8) Error!void {
    std.debug.assert(name.len > 0);

    if (!sandboxed_plugin.valid_name(name)) {
        return error.NotFound;
    }

    try store.sandboxed_plugins.delete(ctx.db, name);
}

pub const Change = enum { grant, revoke, deny };

/// Grants, revokes or denies one request, by its key.
pub fn decide(ctx: *Ctx, name: []const u8, key: []const u8, change: Change) Error!state.Decoded {
    std.debug.assert(name.len > 0);

    var decoded = try state.load(ctx, name);
    const shown = try state.requests_of(
        ctx.arena,
        &decoded.manifest,
        decoded.granted,
        decoded.denied,
    );
    const request = for (shown) |candidate| {
        if (std.mem.eql(u8, candidate.key, key)) {
            break candidate;
        }
    } else {
        return error.NotFound;
    };

    switch (change) {
        .grant => {
            if (request.state == .unavailable) {
                return error.Invalid;
            }

            decoded.granted = try state.with(ctx.arena, decoded.granted, request.key);
            decoded.denied = try state.without(ctx.arena, decoded.denied, request.key);
        },
        .revoke => decoded.granted = try state.without(ctx.arena, decoded.granted, request.key),
        .deny => {
            decoded.granted = try state.without(ctx.arena, decoded.granted, request.key);
            decoded.denied = try state.with(ctx.arena, decoded.denied, request.key);
        },
    }

    try state.save(ctx, decoded);

    return decoded;
}
