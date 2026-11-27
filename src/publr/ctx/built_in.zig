//! What only a built-in plugin's `ctx` does: calling for a person or as Publr itself, the
//! process's I/O, a session it vouched for, a call on a copy of the site. An installed build
//! that asks for any of them does not compile.
const std = @import("std");
const guest = @import("../../sdk/plugin/guest.zig");
const Ctx = @import("../ctx.zig").Ctx;
const Error = @import("../operation.zig").Error;
const public_of = @import("../../sdk/operation.zig").public_of;

fn host(ctx: anytype) @TypeOf(@import("../../sdk/plugin/context.zig").host_of(ctx)) {
    return @import("../../sdk/plugin/context.zig").host_of(ctx);
}

/// The same plugin, calling for one person: every call made through the answer runs as
/// the plugin acting for the account `person` (its id), with the plugin's own grants, so
/// a record it makes names them as its maker and the site's policies judge the person.
/// For a built-in plugin's operations that read and write on a member's behalf after
/// checking what is theirs: an installed build that asks for it does not compile.
pub fn as_person(ctx: *Ctx, person: []const u8) Error!*Ctx {
    if (comptime guest.mode == .sandboxed) {
        @compileError("ctx.as_person() is for a built-in plugin's own operations");
    }

    return host(ctx).as_person(person) catch |err| return public_of(err);
}

/// Whether the caller (the person, through `as_person`) may run `Operation`, as the
/// call itself would be judged: to offer only what they may do. An installed build that
/// asks for it does not compile.
pub fn may(ctx: *const Ctx, comptime Operation: type) bool {
    if (comptime guest.mode == .sandboxed) {
        @compileError("ctx.may() is for a built-in plugin's own code");
    }

    return host(ctx).may(Operation);
}

/// The same plugin, calling as Publr itself: past every role and grant, for work no
/// person and no plugin's grants could do (signing a token for a project's owner while
/// nobody is signed in). Only a built-in plugin, for its own operations: an installed
/// build that asks for it does not compile.
pub fn as_system(ctx: *Ctx) Error!*Ctx {
    if (comptime guest.mode == .sandboxed) {
        @compileError("ctx.as_system() is for a built-in plugin's own operations");
    }

    return host(ctx).as_system() catch |err| return public_of(err);
}

/// The process's I/O, for a built-in plugin's own files and processes. An installed
/// build that asks for it does not compile.
pub fn io(ctx: *const Ctx) std.Io {
    if (comptime guest.mode == .sandboxed) {
        @compileError("ctx.io() is for a built-in plugin's own files");
    }

    return host(ctx).io();
}

/// A sign-in session for the account `user_id`, made as core's sign-in makes one, for a
/// built-in plugin that vouched for the person itself (a one-time link another copy of
/// the site sent). Refused (`BadCredentials`) when the account cannot sign in. An
/// installed build that asks for it does not compile.
pub fn start_session(ctx: *Ctx, user_id: []const u8) Error!Ctx.Session {
    if (comptime guest.mode == .sandboxed) {
        @compileError("ctx.start_session() is for a built-in plugin's own sign-in");
    }

    return host(ctx).start_session(user_id) catch |err| return public_of(err);
}

/// The call runs on a copy of the site (an environment, a branch), not the site itself:
/// what the plugin keeping copies says before a call runs, so a `write` device publishes
/// there. An installed build that asks for it does not compile.
pub fn mark_copy(ctx: *Ctx) void {
    if (comptime guest.mode == .sandboxed) {
        @compileError("ctx.mark_copy() is for the built-in plugin keeping copies");
    }

    host(ctx).mark_copy();
}

/// The installed plugins' rows changed underneath them (another copy's brought in): the
/// sandbox loads them again. An installed build that asks for it does not compile.
pub fn reload_plugins(ctx: *Ctx) void {
    if (comptime guest.mode == .sandboxed) {
        @compileError("ctx.reload_plugins() is for a built-in plugin");
    }

    host(ctx).reload_plugins();
}
