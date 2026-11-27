//! What only a built-in plugin's `ctx` does until installed plugins may (the spec's
//! M8): calling for a person, and a session it vouched for. An installed build that asks
//! for either does not compile.
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
