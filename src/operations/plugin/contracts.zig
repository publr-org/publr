//! The remotes between plugins, checked whenever one changes: enabling a plugin checks what
//! it uses; updating one checks it and every enabled plugin that uses it. A required remote
//! that does not fit refuses the change; an optional one is off (its calls answer
//! `Unavailable`, its hooks don't run) until it fits; `plugin get` says which and why.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const registry = @import("../../server/registry.zig");
const state = @import("state.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const Manifest = model.sandboxed_plugin.Manifest;
const fit = model.plugin_contracts;

pub const ProvidersOptions = struct {
    /// An update about to land: it stands in for the installed plugin of its name.
    replacing: ?*const Manifest = null,
};

/// What is there now: every compiled-in plugin and every enabled installed one.
pub fn providers(ctx: *Ctx, options: ProvidersOptions) Error![]const fit.Provider {
    const replacing = options.replacing;

    std.debug.assert(ctx.now_ms >= 0);
    var list: std.ArrayList(fit.Provider) = .empty;
    const natives = registry.native_providers(ctx.arena) catch return error.OutOfMemory;

    std.debug.assert(natives.len <= 64);

    list.appendSlice(ctx.arena, natives) catch return error.OutOfMemory;

    for (try installed(ctx)) |manifest| {
        const stands_in = replacing != null and std.mem.eql(u8, replacing.?.name, manifest.name);

        if (!stands_in) {
            try append(ctx, &list, &manifest);
        }
    }

    if (replacing) |manifest| {
        try append(ctx, &list, manifest);
    }

    return list.items;
}

/// Refused, in plain words, when a remote the plugin needs does not fit what is there.
pub fn check_user(ctx: *Ctx, manifest: *const Manifest, there: []const fit.Provider) Error!void {
    std.debug.assert(manifest.name.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    var found: [fit.findings_max]fit.Finding = undefined;
    const count = fit.check(user_of(manifest), there, &found);

    for (found[0..count]) |finding| {
        if (finding.required) {
            var buffer: [256]u8 = undefined;
            const why = fit.describe(finding, &buffer);
            const message = std.fmt.allocPrint(ctx.arena, "{s} can't be enabled: {s}", .{
                manifest.name,
                why,
            }) catch return error.OutOfMemory;

            return ctx.fail(.{
                .name = "ContractMismatch",
                .status = 409,
                .message = message,
            });
        }
    }
}

/// An update of `replacing` checked both ways: what it uses, and every enabled installed
/// plugin that needs it.
pub fn check_update(ctx: *Ctx, replacing: *const Manifest) Error!void {
    std.debug.assert(replacing.name.len > 0);

    const there = try providers(ctx, .{
        .replacing = replacing,
    });

    try check_user(ctx, replacing, there);

    for (try installed(ctx)) |manifest| {
        if (!std.mem.eql(u8, manifest.name, replacing.name)) {
            try check_user(ctx, &manifest, there);
        }
    }
}

/// A remote switched off, and why, in plain words.
pub const Off = struct {
    name: []const u8,
    why: []const u8,
};

/// Where the plugin's remotes stand now: what keeps it from being enabled, and which are off.
pub const Standing = struct {
    blocked: []const []const u8,
    off: []const Off,
};

/// The plugin's remotes that do not fit what is there: what `plugin get` shows.
pub fn standing(ctx: *Ctx, manifest: *const Manifest) Error!Standing {
    std.debug.assert(manifest.name.len > 0);

    const there = try providers(ctx, .{});
    var found: [fit.findings_max]fit.Finding = undefined;
    const count = fit.check(user_of(manifest), there, &found);
    var blocked: std.ArrayList([]const u8) = .empty;
    var off: std.ArrayList(Off) = .empty;

    for (found[0..count]) |finding| {
        const why = try words_of(ctx, finding);

        if (finding.required) {
            blocked.append(ctx.arena, why) catch return error.OutOfMemory;
        } else {
            off.append(ctx.arena, .{
                .name = finding.name,
                .why = why,
            }) catch return error.OutOfMemory;
        }
    }

    return .{
        .blocked = blocked.items,
        .off = off.items,
    };
}

/// The built-in plugins' remotes that are off now, each named `plugin: remote`, and why:
/// what the Built-in tab shows. A built-in plugin always runs, so whatever does not fit is
/// off, whether it needs it or only works with it.
pub fn native_off(ctx: *Ctx) Error![]const Off {
    std.debug.assert(ctx.now_ms >= 0);

    const there = try providers(ctx, .{});
    const users = registry.native_users();
    var found: [fit.findings_max]fit.Finding = undefined;
    var off: std.ArrayList(Off) = .empty;

    std.debug.assert(users.len <= 64);

    for (users) |user| {
        const count = fit.check(user, there, &found);

        for (found[0..count]) |finding| {
            const named = std.fmt.allocPrint(ctx.arena, "{s}: {s}", .{
                user.plugin,
                finding.name,
            }) catch return error.OutOfMemory;

            off.append(ctx.arena, .{
                .name = named,
                .why = try words_of(ctx, finding),
            }) catch return error.OutOfMemory;
        }
    }

    return off.items;
}

/// What applying an update of `replacing` would do to the other enabled plugins: the ones
/// that need it as it is (they stop the update), and the remotes it would switch off.
pub const Effects = struct {
    stops: []const []const u8,
    switches_off: []const []const u8,
};

pub fn update_effects(ctx: *Ctx, replacing: *const Manifest) Error!Effects {
    std.debug.assert(replacing.name.len > 0);

    const now = try providers(ctx, .{});
    const after = try providers(ctx, .{
        .replacing = replacing,
    });
    var stops: std.ArrayList([]const u8) = .empty;
    var switches_off: std.ArrayList([]const u8) = .empty;
    var found: [fit.findings_max]fit.Finding = undefined;

    var users: std.ArrayList(fit.User) = .empty;

    users.appendSlice(ctx.arena, registry.native_users()) catch return error.OutOfMemory;

    for (try installed(ctx)) |*manifest| {
        if (!std.mem.eql(u8, manifest.name, replacing.name)) {
            users.append(ctx.arena, user_of(manifest)) catch return error.OutOfMemory;
        }
    }

    for (users.items) |user| {
        const count = fit.check(user, after, &found);

        for (found[0..count]) |finding| {
            if (!fit.remote_on(user, now, finding.name)) {
                continue;
            }

            const why = try words_of(ctx, finding);
            const line = std.fmt.allocPrint(ctx.arena, "{s}: {s}", .{ user.plugin, why }) catch
                return error.OutOfMemory;
            const list = if (finding.required) &stops else &switches_off;

            list.append(ctx.arena, line) catch return error.OutOfMemory;
        }
    }

    return .{
        .stops = stops.items,
        .switches_off = switches_off.items,
    };
}

fn words_of(ctx: *Ctx, finding: fit.Finding) Error![]const u8 {
    var buffer: [256]u8 = undefined;
    const text = fit.describe(finding, &buffer);

    std.debug.assert(finding.name.len > 0);

    return ctx.arena.dupe(u8, text) catch error.OutOfMemory;
}

pub fn user_of(manifest: *const Manifest) fit.User {
    return model.sandboxed_plugin.contract_user(manifest);
}

fn append(ctx: *Ctx, list: *std.ArrayList(fit.Provider), manifest: *const Manifest) Error!void {
    std.debug.assert(manifest.name.len > 0);

    const provider = model.sandboxed_plugin.contract_provider(ctx.arena, manifest) catch {
        return error.OutOfMemory;
    };

    list.append(ctx.arena, provider) catch return error.OutOfMemory;
}

/// The manifests of the enabled installed plugins.
fn installed(ctx: *Ctx) Error![]const Manifest {
    std.debug.assert(ctx.now_ms >= 0);

    const rows = try store.sandboxed_plugins.list(ctx.db, ctx.arena);
    var manifests: std.ArrayList(Manifest) = .empty;

    for (rows) |row| {
        if (row.enabled) {
            const manifest = try state.parse_manifest(ctx.arena, row.manifest);

            manifests.append(ctx.arena, manifest) catch return error.OutOfMemory;
        }
    }

    return manifests.items;
}

const contract = model.contract;

const Reserve = struct {
    sku: []const u8,
    quantity: u32,
};

fn test_manifest(
    comptime Sends: type,
    depends: []const []const u8,
    works: []const []const u8,
) Manifest {
    std.debug.assert(depends.len + works.len > 0);

    return .{
        .format = model.sandboxed_plugin.format,
        .name = "cart",
        .version = "0.1.0",
        .summary = "Uses inventory",
        .depends_on = depends,
        .compatible_with = works,
        .remotes = &.{.{
            .name = "inventory.reserve",
            .input = comptime contract.describe(Sends),
            .output = comptime contract.describe(struct {
                held: bool,
            }),
        }},
    };
}

test "contracts: a required misfit refuses, an optional one does not" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.system);
    const there = [_]fit.Provider{.{
        .plugin = "inventory",
        .version = "1.4.0",
        .operations = &.{.{
            .name = "inventory.reserve",
            .input = comptime contract.describe(Reserve),
            .output = comptime contract.describe(struct {
                held: bool,
                left: u32,
            }),
        }},
    }};

    const fits = test_manifest(Reserve, &.{"inventory@^1"}, &.{});
    try check_user(&ctx, &fits, &there);

    const required = test_manifest(struct {
        sku: []const u8,
    }, &.{"inventory@^1"}, &.{});
    try std.testing.expectError(error.Failed, check_user(&ctx, &required, &there));

    const optional = test_manifest(struct {
        sku: []const u8,
    }, &.{}, &.{"inventory"});
    try check_user(&ctx, &optional, &there);

    const too_new = test_manifest(Reserve, &.{"inventory@^2"}, &.{});
    try std.testing.expectError(error.Failed, check_user(&ctx, &too_new, &there));
}
