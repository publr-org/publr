//! What only a built-in plugin's `ctx` does, past calling operations: the process's I/O, a
//! session for a person it vouched for, marking the call as one on a copy of the site.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const context = @import("context.zig");

const HostApi = context.HostApi;
const Error = sdk.Error;

pub fn io(api: *const HostApi) std.Io {
    std.debug.assert(api.inner.now_ms >= 0);

    return api.inner.io;
}

pub const Session = @import("../../publr/ctx/session.zig").Session;

/// A new session for `user_id`, made as core's sign-in makes one: refused (`BadCredentials`)
/// for an account that does not exist or cannot sign in.
pub fn start_session(api: *HostApi, user_id: []const u8) Error!Session {
    const inner = api.inner;

    std.debug.assert(inner.db.transaction_depth >= 1 or inner.now_ms >= 0);

    if (user_id.len == 0 or user_id.len > sdk.caller.id_len_max) {
        return error.Invalid;
    }

    const found = try store.users.find_by_id(inner.db, inner.arena, user_id) orelse {
        return error.BadCredentials;
    };

    if (!found.user.active) {
        return error.BadCredentials;
    }

    const sessions = store.sessions;
    const created = try sessions.create(inner.db, inner.io, inner.arena, user_id, inner.now_ms);

    return .{
        .token = inner.arena.dupe(u8, created.token_text()) catch return error.OutOfMemory,
        .user_id = found.user.id,
        .expires_at_ms = created.session.expires_at,
    };
}

/// The call runs on a copy of the site (an environment, a branch), not the site itself: what
/// the plugin keeping copies says of a request before it runs.
pub fn mark_copy(api: *HostApi) void {
    std.debug.assert(api.inner.now_ms >= 0);

    api.inner.on_copy = true;
}

/// `text`, a message marked where it was written (`publr.t`), in the language `code`, each
/// `{name}` filled from `values`.
pub fn said_values(
    api: *const HostApi,
    code: []const u8,
    text: []const u8,
    values: []const sdk.context.Message.Value,
) error{OutOfMemory}![]const u8 {
    std.debug.assert(text.len > 0);
    std.debug.assert(values.len <= 64);

    return api.inner.say(code, .{
        .id = text,
        .values = values,
    });
}

/// The installed plugins' rows were changed underneath them (a copy's plugins brought in):
/// the sandbox loads them again, as after `plugin.apply`.
pub fn reload_plugins(api: *HostApi) void {
    const inner = api.inner;
    const sandboxed = inner.sandboxed_plugins orelse return;

    std.debug.assert(inner.now_ms >= 0);

    sandboxed.event(inner, .{
        .completed = .{
            .operation_name = "plugin.applied",
            .operation_id = inner.allocate_operation_id(),
        },
    });
}

test "a built-in plugin's session needs an account that signs in; a copy is marked" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var inner = harness.ctx(.system);
    var api: HostApi = .{
        .inner = &inner,
    };

    try std.testing.expectError(error.Invalid, api.start_session(""));
    try std.testing.expectError(error.BadCredentials, api.start_session("u_nobody"));
    try std.testing.expect(!inner.on_copy);

    api.mark_copy();

    try std.testing.expect(inner.on_copy);
    _ = api.io();
}
