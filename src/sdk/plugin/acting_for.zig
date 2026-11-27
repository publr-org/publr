//! A built-in plugin calling for one person (`ctx.as_person`), and asking what its caller may
//! run (`ctx.may`). Core makes the caller: the plugin, for the account, with the grants it
//! was compiled with; the site's policies and roles judge each call as they judge any other.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const store = @import("../../store.zig");
const context = @import("context.zig");
const id_len_max = @import("../caller.zig").id_len_max;

const HostApi = context.HostApi;
const Error = sdk.Error;

/// The grants of a compiled-in plugin that asked for none.
const no_access: @import("../plugin_access.zig").Access = .{
    .own_types = &.{},
};

/// The caller a `HostApi` made by `as_person` stands for, in place for one call and put back
/// after it.
pub const Acting = struct {
    inner: *sdk.Ctx,
    saved: sdk.Caller,

    pub fn end(acting: Acting) void {
        std.debug.assert(acting.inner.now_ms >= 0);

        acting.inner.caller = acting.saved;
    }
};

pub fn begin(api: *const HostApi) Acting {
    const acting: Acting = .{
        .inner = api.inner,
        .saved = api.inner.caller,
    };

    if (api.person) |person| {
        std.debug.assert(person == .plugin or person == .system);

        api.inner.caller = person;
    }

    return acting;
}

pub fn as_person(api: *HostApi, person: []const u8) Error!*context.PluginCtx {
    const inner = api.inner;

    std.debug.assert(inner.now_ms >= 0);

    if (person.len == 0 or person.len > id_len_max) {
        return error.Invalid;
    }

    // Core's own code is no plugin: it has no grants to act with.
    if (inner.plugin.len == 0) {
        return error.Denied;
    }

    const made = inner.arena.create(HostApi) catch return error.OutOfMemory;

    made.* = .{
        .inner = inner,
        .reads = api.reads,
        .person = .{
            .plugin = .{
                .name = inner.plugin,
                .on_behalf_of = inner.arena.dupe(u8, person) catch return error.OutOfMemory,
                .access = registry.SDK.compiled_access(inner.plugin),
                .roles = try roles_of(inner, person),
                .for_person = true,
            },
        },
    };

    return made.ctx();
}

/// The roles the account holds, for what the person's own standing decides (the site's
/// answer for an operation, what no grant names); none for an account that cannot sign in.
fn roles_of(inner: *sdk.Ctx, person: []const u8) Error![]const []const u8 {
    std.debug.assert(person.len > 0);

    const found = try store.users.find_by_id(inner.db, inner.arena, person) orelse return &.{};

    if (!found.user.active) {
        return &.{};
    }

    std.debug.assert(found.user.roles.len <= @import("../../model/role.zig").user_roles_max);

    return found.user.roles;
}

pub fn as_system(api: *HostApi) Error!*context.PluginCtx {
    const inner = api.inner;

    std.debug.assert(inner.now_ms >= 0);

    // Core's own code needs no stand-in: it calls as the system already.
    if (inner.plugin.len == 0) {
        return error.Denied;
    }

    const made = inner.arena.create(HostApi) catch return error.OutOfMemory;

    made.* = .{
        .inner = inner,
        .reads = api.reads,
        .person = .system,
    };

    return made.ctx();
}

/// The plugin calling as itself, with no person behind it: the caller an installed plugin's
/// calls run as, its compiled grants deciding and no account's roles narrowing them.
pub fn as_plugin(api: *HostApi) Error!*context.PluginCtx {
    const inner = api.inner;

    std.debug.assert(inner.now_ms >= 0);

    // Core's own code is no plugin: it has no grants to act with.
    if (inner.plugin.len == 0) {
        return error.Denied;
    }

    const made = inner.arena.create(HostApi) catch return error.OutOfMemory;

    made.* = .{
        .inner = inner,
        .reads = api.reads,
        .person = .{
            .plugin = .{
                .name = inner.plugin,
                .access = registry.SDK.compiled_access(inner.plugin) orelse &no_access,
            },
        },
    };

    return made.ctx();
}

pub fn may(api: *const HostApi, comptime Operation: type) bool {
    std.debug.assert(api.inner.now_ms >= 0);

    const acting = begin(api);
    defer acting.end();

    return registry.SDK.may(api.inner, Operation);
}

test "a plugin calls for a person with its own grants, and its caller is put back" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var inner = harness.ctx(.{
        .user = .{
            .id = "u_1",
        },
    });
    var api: HostApi = .{
        .inner = &inner,
    };

    try std.testing.expectError(error.Denied, api.as_person("u_2"));

    inner.plugin = "hello";

    try std.testing.expectError(error.Invalid, api.as_person(""));

    const person = context.host_of(try api.as_person("u_2"));
    const seen = person.caller();

    try std.testing.expectEqualStrings("u_2", seen.user_id().?);
    try std.testing.expect(seen.from == .plugin);
    try std.testing.expectEqualStrings("u_1", inner.caller.user_id().?);
    try std.testing.expect(api.may(@import("../../publr/operations/role.zig").List));
    try std.testing.expect(!person.may(@import("../../publr/operations/role.zig").Create));
    try std.testing.expect(inner.caller == .user);

    const system = context.host_of(try api.as_system());

    try std.testing.expect(system.caller().system);
    try std.testing.expect(!api.caller().system);
}

test "a plugin calls as itself with its own grants, no person behind them" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var inner = harness.ctx(.{
        .user = .{
            .id = "u_1",
        },
    });
    var api: HostApi = .{
        .inner = &inner,
    };

    try std.testing.expectError(error.Denied, api.as_plugin());

    inner.plugin = "hello";

    const alone = context.host_of(try api.as_plugin());
    const seen = alone.caller();

    try std.testing.expect(seen.user_id() == null);
    try std.testing.expect(!seen.system);
    try std.testing.expect(!seen.signed_in());
    try std.testing.expect(!alone.may(@import("../../publr/operations/role.zig").List));
    try std.testing.expect(inner.caller == .user);
}
