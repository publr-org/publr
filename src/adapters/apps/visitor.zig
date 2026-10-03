//! The visitor's stable id: the `publr_visitor` cookie, a random id set by the first
//! dynamic page, dynamic island or `_api` call that finds none. Never by a static page, so
//! built pages stay cacheable. Signed in or not, it stays the same, beside the user.

const std = @import("std");
const http = @import("../../lib/http.zig");
const ids = @import("../../lib/id.zig");
const identity = @import("../rest/identity.zig");
const Project = @import("../../server/project.zig").Project;

pub const cookie_name = "publr_visitor";
/// A year: long enough that a returning visitor keeps their cart.
pub const max_age_s: u32 = 365 * 24 * 60 * 60;

/// The visitor's id: the cookie's when it holds one, else a new one, set on the response.
pub fn ensure(
    project: *const Project,
    request: *const http.Request,
    response: *http.Response,
    arena: std.mem.Allocator,
) http.Error![]const u8 {
    std.debug.assert(project.connection.transaction_depth == 0);
    std.debug.assert(request.path().len > 0);

    if (of(request)) |known| {
        return known;
    }

    var buffer: [ids.len]u8 = undefined;
    const fresh = try arena.dupe(u8, ids.random(project.io, &buffer));
    const value = std.fmt.allocPrint(arena, "{s}={s}; Path=/; HttpOnly; SameSite=Lax; " ++
        "Max-Age={d}{s}{s}{s}", .{
        cookie_name,
        fresh,
        max_age_s,
        identity.domain_label(project),
        identity.domain_of(project),
        identity.secure_suffix(request),
    }) catch return error.OutOfMemory;

    try response.add_header("Set-Cookie", value);

    return fresh;
}

/// The id the request's cookie holds, when it is one Publr could have made.
pub fn of(request: *const http.Request) ?[]const u8 {
    std.debug.assert(cookie_name.len > 0);

    const header = request.header("cookie") orelse return null;
    const value = identity.cookie_value(header, cookie_name) orelse return null;

    if (value.len != ids.len) {
        return null;
    }

    for (value) |char| {
        if (!std.ascii.isHex(char)) {
            return null;
        }
    }

    return value;
}
