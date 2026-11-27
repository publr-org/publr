//! A built-in plugin calling for one person (`ctx.as_person`), and asking what its caller may
//! run (`ctx.may`). Core makes the caller: the plugin, for the account, with the grants it
//! was compiled with; the site's policies and roles judge each call as they judge any other.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const context = @import("context.zig");
const id_len_max = @import("../caller.zig").id_len_max;

const HostApi = context.HostApi;
const Error = sdk.Error;

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
        std.debug.assert(person == .plugin);

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
}
