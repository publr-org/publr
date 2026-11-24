//! A plugin's update may take an operation from visitors (`.untrusted_callers` dropped). A
//! role a type of user gives that granted it by name would then reach what staff call, so
//! the grant goes: dropped, never kept, so a type never holds staff power, with the event
//! `role.grant_dropped` when an operation is running (enable, update, roll back) and a line
//! in the log at boot (a compiled-in plugin's new build). The rest of the role stays.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const role = @import("../../model/role.zig");
const role_operations = @import("../role.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;

/// Drops from each role in `given` every grant naming, by its exact name, an operation of a
/// plugin `plugins.owns` that is not one `visitors.is_visitor` now: what a type gives stays a
/// visitor's. Answers how many grants went.
pub fn drop(ctx: *Ctx, given: []const []const u8, plugins: anytype, visitors: anytype) Error!u32 {
    std.debug.assert(given.len <= role.roles_max * 16);
    std.debug.assert(ctx.now_ms >= 0);

    var dropped: u32 = 0;

    for (given) |name| {
        if (!try sdk.stored_roles.exists(ctx, name)) {
            continue;
        }

        const grants = try store.role_grants.of(ctx.db, ctx.arena, name);
        var gone: std.ArrayList([]const u8) = .empty;

        for (grants) |grant| {
            if (stale(grant, plugins, visitors)) {
                gone.append(ctx.arena, grant) catch return error.OutOfMemory;
            }
        }

        if (gone.items.len == 0) {
            continue;
        }

        try store.role_grants.remove(ctx.db, name, gone.items);
        dropped += @intCast(gone.items.len);
        tell(ctx, name, gone.items);
    }

    return dropped;
}

/// Whether `grant` names one plugin operation, by name, that visitors no longer call.
fn stale(grant: []const u8, plugins: anytype, visitors: anytype) bool {
    std.debug.assert(grant.len > 0);
    std.debug.assert(grant.len <= role.grant_len_max + 1);

    if (grant[0] == '!' or std.mem.indexOfScalar(u8, grant, '*') != null) {
        return false;
    }

    const dot = std.mem.indexOfScalar(u8, grant, '.') orelse return false;

    if (!plugins.owns(grant[0..dot])) {
        return false;
    }

    return !visitors.is_visitor(grant);
}

fn tell(ctx: *Ctx, name: []const u8, gone: []const []const u8) void {
    std.debug.assert(name.len > 0);
    std.debug.assert(gone.len > 0);

    for (gone) |grant| {
        if (ctx.parent == null) {
            std.log.warn("role {s}: {s} dropped: a type of user gives the role, and " ++
                "visitors no longer call it", .{ name, grant });
        } else {
            ctx.emit(role_operations.GrantDropped, .{
                .role = name,
                .grant = grant,
            });
        }
    }
}

test "an operation taken from visitors leaves the roles types give, nothing else" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);

    // Inside an operation: what is dropped is told as an event, not in the log.
    system.parent = 1;
    try sdk.stored_roles.declare(&system, "porch", &.{.{
        .name = "guest",
        .label = "Guest",
    }});
    try store.role_grants.set(system.db, "guest", &.{
        "porch.knock", "porch.ring", "porch.*", "!porch.mend", "app.porch.*", "news.read",
        "record.get",
    });

    const Plugins = struct {
        fn owns(_: @This(), name: []const u8) bool {
            return std.mem.eql(u8, name, "porch");
        }
    };
    const Visitors = struct {
        fn is_visitor(_: @This(), name: []const u8) bool {
            return std.mem.eql(u8, name, "porch.ring");
        }
    };
    const plugins: Plugins = .{};
    const visitors: Visitors = .{};

    try std.testing.expectEqual(@as(u32, 1), try drop(&system, &.{"guest"}, plugins, visitors));
    try std.testing.expectEqual(@as(u32, 0), try drop(&system, &.{"guest"}, plugins, visitors));
    try std.testing.expectEqual(@as(u32, 0), try drop(&system, &.{"ghost"}, plugins, visitors));

    const kept = try store.role_grants.of(system.db, system.arena, "guest");

    try std.testing.expectEqual(@as(usize, 6), kept.len);

    for (kept) |grant| {
        try std.testing.expect(!std.mem.eql(u8, grant, "porch.knock"));
    }
}

/// The plugins compiled in: at boot, a new build may have taken an operation from visitors.
const Compiled = struct {
    pub fn owns(_: Compiled, name: []const u8) bool {
        std.debug.assert(name.len > 0);

        inline for (@import("../../server/registry.zig").native_plugins.all) |Plugin| {
            if (std.mem.eql(u8, Plugin.manifest.name, name)) {
                return true;
            }
        }

        return false;
    }
};

/// At boot: the roles types give lose each grant of a compiled-in plugin's operation that
/// its build no longer opens to visitors.
pub fn drop_compiled(ctx: *Ctx) Error!u32 {
    std.debug.assert(ctx.caller == .system);
    std.debug.assert(ctx.now_ms >= 0);

    const given = try @import("../../sdk/user_types.zig").roles_given(ctx);

    return drop(ctx, given, Compiled{}, sdk.stored_roles.Visitors{
        .ctx = ctx,
    });
}

/// An installed plugin's version, as its manifest says: its own operations, and which of
/// them visitors call.
const Installed = struct {
    manifest: *const Manifest,

    pub fn owns(installed: Installed, name: []const u8) bool {
        std.debug.assert(name.len > 0);

        return std.mem.eql(u8, installed.manifest.name, name);
    }

    pub fn is_visitor(installed: Installed, name: []const u8) bool {
        std.debug.assert(name.len > 0);

        for (installed.manifest.operations) |operation| {
            if (std.mem.eql(u8, operation.name, name)) {
                return operation.open or (operation.untrusted_callers orelse false);
            }
        }

        return false;
    }
};

const Manifest = @import("../../model/sandboxed_plugin.zig").Manifest;

/// Enabling, updating or rolling back an installed plugin: the roles types give (its own
/// types' included) lose each grant of its operations this version does not open to visitors.
pub fn drop_installed(ctx: *Ctx, manifest: *const Manifest) Error!u32 {
    std.debug.assert(manifest.name.len > 0);
    std.debug.assert(manifest.user_types.len <= 64);

    var given: std.ArrayList([]const u8) = .empty;

    given.appendSlice(ctx.arena, try @import("../../sdk/user_types.zig").roles_given(ctx)) catch {
        return error.OutOfMemory;
    };

    for (manifest.user_types) |declared| {
        given.appendSlice(ctx.arena, declared.roles) catch return error.OutOfMemory;
    }

    const installed: Installed = .{
        .manifest = manifest,
    };

    return drop(ctx, given.items, installed, installed);
}

/// The plugin's own operations as its manifest says, every other one as it is here now.
const Combined = struct {
    installed: Installed,
    here: sdk.stored_roles.Visitors,

    pub fn is_visitor(combined: Combined, name: []const u8) bool {
        std.debug.assert(name.len > 0);

        const dot = std.mem.indexOfScalar(u8, name, '.') orelse return false;

        if (combined.installed.owns(name[0..dot])) {
            return combined.installed.is_visitor(name);
        }

        return combined.here.is_visitor(name);
    }
};

/// The first role `declared` (a type `manifest` registers) gives that is staff, its own
/// operations read from the manifest being enabled; null when it gives visitor roles only.
pub fn staff_given(
    ctx: *Ctx,
    manifest: *const Manifest,
    declared: @import("../../model/user_type.zig").Declared,
) Error!?[]const u8 {
    std.debug.assert(manifest.name.len > 0);
    std.debug.assert(declared.name.len > 0);

    const combined: Combined = .{
        .installed = .{
            .manifest = manifest,
        },
        .here = .{
            .ctx = ctx,
        },
    };

    for (declared.roles) |name| {
        if (!try sdk.stored_roles.exists(ctx, name)) {
            continue;
        }

        const grants = try store.role_grants.of(ctx.db, ctx.arena, name);

        if (role.staff_grants(grants, combined)) {
            return name;
        }
    }

    return null;
}
