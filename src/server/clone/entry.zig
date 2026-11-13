//! Opening a clone's admin signed in, as the account that cloned it, without a password to
//! type (a Cloud account may have none). Before the clone is served, a session for that
//! account is made in its database; the progress server, on the very address the site's
//! own server takes next, gives the browser that session's cookie once.
const std = @import("std");
const db = @import("../../lib/db.zig");
const settings = @import("../../store/settings.zig");
const sessions = @import("../../store/sessions.zig");
const users = @import("../../store/users.zig");
const identity = @import("../../adapters/rest/identity.zig");
const project_operations = @import("../../operations/project.zig");

const database_path = "data/publr.db";

/// The two cookies a sign-in sets, ready to send: the session, and the hint that says one
/// is there.
pub const Entered = struct {
    session_cookie: []const u8,
    hint_cookie: []const u8,
};

/// A session for `email` in the clone in `folder`, as the cookies its server will know.
pub fn session_for(
    io: std.Io,
    arena: std.mem.Allocator,
    folder: []const u8,
    email: []const u8,
    now_ms: i64,
) !Entered {
    std.debug.assert(folder.len > 0);
    std.debug.assert(email.len > 0);

    var runtime = try db.Runtime.init(.{});
    defer runtime.deinit();

    var connection = try db.open(&runtime, try std.fs.path.joinZ(arena, &.{
        folder,
        database_path,
    }));
    defer connection.close();

    const found = try users.find_by_email(&connection, arena, email) orelse {
        return error.AccountNotCloned;
    };
    const created = try sessions.create(&connection, io, arena, found.user.id, now_ms);
    const set_up = try settings.get(&connection, arena, project_operations.setup_key);
    const names: Names = if (set_up) |secret| blk: {
        const marked = try identity.cookie_names(arena, secret);

        break :blk .{
            .session = marked.session,
            .hint = marked.hint,
        };
    } else .{
        .session = identity.cookie_name,
        .hint = identity.hint_cookie_name,
    };

    return cookies(arena, names, created.token_text());
}

const Names = struct {
    session: []const u8,
    hint: []const u8,
};

fn cookies(arena: std.mem.Allocator, names: Names, token: []const u8) !Entered {
    std.debug.assert(token.len > 0);

    const max_age = @divTrunc(sessions.lifetime_ms, std.time.ms_per_s);

    return .{
        .session_cookie = try std.fmt.allocPrint(arena, "{s}={s}; Path=/; HttpOnly; " ++
            "SameSite=Lax; Max-Age={d}", .{ names.session, token, max_age }),
        .hint_cookie = try std.fmt.allocPrint(arena, "{s}=1; Path=/; SameSite=Lax; " ++
            "Max-Age={d}", .{ names.hint, max_age }),
    };
}

test "a clone's cookies are its own names, with a session's lifetime" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const made = try cookies(arena_state.allocator(), .{
        .session = "publr_session_ab12",
        .hint = "publr_signed_in_ab12",
    }, "token");

    const session = "publr_session_ab12=token;";

    try std.testing.expect(std.mem.startsWith(u8, made.session_cookie, session));
    try std.testing.expect(std.mem.indexOf(u8, made.session_cookie, "HttpOnly") != null);
    try std.testing.expect(std.mem.startsWith(u8, made.hint_cookie, "publr_signed_in_ab12=1;"));
}
