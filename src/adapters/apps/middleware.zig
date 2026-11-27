//! An app's middleware as the site runs it (`publr/app_middleware.zig` is what it is given
//! and answers with): asked before core answers an address the app may answer itself, its
//! answer written as given and never cached.

const std = @import("std");
const http = @import("../../lib/http.zig");
const context_module = @import("context.zig");
const public = @import("../../publr/app_middleware.zig");
const Project = @import("../../server/project.zig").Project;
const App = @import("state.zig").App;

pub const Request = public.Request;
pub const Response = public.Response;
pub const User = public.User;

/// What a middleware's `Request` holds of the request besides its path.
pub const Seen = struct {
    project: *const Project,
    app: *const App,
    http: *const http.Request,
    identity: @import("../rest/identity.zig").Identity,
};

pub const body_bytes_max: u32 = 1 << 20;

/// Middleware as the site runs it.
pub const Middleware = *const fn (request: *Request) anyerror!?Response;

/// Asks the middleware of the app at the request's host and path, before core answers an
/// address an app may answer itself: true when it answered.
pub fn first(incoming: *const http.Request, response: *http.Response, ctx: *http.Context) !bool {
    std.debug.assert(ctx.user_data != null);
    std.debug.assert(incoming.path().len > 0);

    const project = Project.of(ctx);

    if (project.apps_failed) {
        return false;
    }

    const host = incoming.header("host") orelse "";
    const target = project.resolve(host, incoming.path()) orelse return false;

    return answer(project, target.app, target.path, ctx.arena, incoming, response);
}

/// Asks the app's middleware about the request: true when it answered, and `response`
/// holds its answer.
pub fn answer(
    project: *const Project,
    app: *const App,
    inside: []const u8,
    arena: std.mem.Allocator,
    incoming: *const http.Request,
    response: *http.Response,
) !bool {
    std.debug.assert(incoming.path().len > 0);
    std.debug.assert(inside.len > 0);

    const run = app.middleware orelse return false;
    const seen: Seen = .{
        .project = project,
        .app = app,
        .http = incoming,
        .identity = context_module.identify(project, app, arena, incoming),
    };
    var request: Request = .{
        .arena = arena,
        .inside = inside,
        .seen = &seen,
    };
    const given = try run(&request) orelse return false;

    try write(response, given);

    return true;
}

fn write(response: *http.Response, given: Response) !void {
    std.debug.assert(response.body.len == 0);

    const status = std.enums.fromInt(http.Status, given.status) orelse return error.Invalid;
    const redirecting = given.status >= 300 and given.status < 400;

    if (redirecting != (given.location.len > 0) or given.body.len > body_bytes_max) {
        return error.Invalid;
    }

    if (given.headers.len > Response.headers_max) {
        return error.Invalid;
    }

    // Middleware answers per request, often per visitor: no shared cache keeps it.
    try response.set_header("Cache-Control", "private, no-store");

    for (given.headers) |header| {
        try response.add_header(header.name, header.value);
    }

    if (redirecting) {
        return response.redirect(status, given.location);
    }

    try response.set_body(status, given.content_type, given.body);
}

test "an answer is written as given, and a redirect must name where" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var response: http.Response = .{
        .arena = arena_state.allocator(),
    };

    try write(&response, .{
        .status = 303,
        .location = "https://ada.publr.app/",
    });
    try std.testing.expectEqual(http.Status.see_other, response.status);
    try std.testing.expectEqualStrings("https://ada.publr.app/", response.header("Location").?);
    try std.testing.expectEqualStrings("private, no-store", response.header("Cache-Control").?);

    var page: http.Response = .{
        .arena = arena_state.allocator(),
    };

    try write(&page, .{
        .status = 402,
        .body = "<p>Members only</p>",
    });
    try std.testing.expectEqual(@as(u16, 402), page.status.code());

    var broken: http.Response = .{
        .arena = arena_state.allocator(),
    };

    try std.testing.expectError(error.Invalid, write(&broken, .{
        .status = 303,
    }));
    try std.testing.expectError(error.Invalid, write(&broken, .{
        .status = 200,
        .location = "/",
    }));
    try std.testing.expectError(error.Invalid, write(&broken, .{
        .status = 299,
    }));
}
