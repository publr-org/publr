//! Middleware: an app's `middleware.zig`, compiled in, sees every request for the app
//! before anything else does (pages, not-found pages, islands, any method) and either
//! answers it or lets it through. `/admin`, `/api`, `/auth` and the app's assets are
//! core's and never reach it.
//!
//! ```zig
//! const std = @import("std");
//! const publr = @import("publr");
//!
//! pub fn middleware(request: *publr.Request) !?publr.Response {
//!     if (!request.starts_with("/members")) return null;
//!     if (request.user() == null) return request.redirect("/login");
//!     return null;
//! }
//! ```
//!
//! `null` lets the request through; a `Response` is the answer, never cached.

const std = @import("std");
const http = @import("../../lib/http.zig");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const identity_module = @import("../rest/identity.zig");
const context_module = @import("context.zig");
const Project = @import("../../server/project.zig").Project;
const App = @import("state.zig").App;

pub const body_bytes_max: u32 = 1 << 20;

/// Middleware as the site runs it.
pub const Middleware = *const fn (request: *Request) anyerror!?Response;

/// The answer middleware gives in the site's place.
pub const Response = struct {
    status: u16,
    /// Where a redirect goes: any URL, this site's or another's.
    location: []const u8 = "",
    content_type: []const u8 = "text/html; charset=utf-8",
    body: []const u8 = "",
};

/// The signed-in visitor.
pub const User = struct {
    id: []const u8,
    email: []const u8,
    display_name: []const u8,
    /// The names of the roles the visitor holds.
    roles: []const []const u8,

    /// Whether the visitor holds the role `name`.
    pub fn holds(user: *const User, name: []const u8) bool {
        std.debug.assert(name.len > 0);
        std.debug.assert(user.roles.len <= 16);

        for (user.roles) |held| {
            if (std.mem.eql(u8, held, name)) {
                return true;
            }
        }

        return false;
    }
};

/// What middleware sees of a request, and how it answers one. Everything it allocates
/// lives as long as the request.
pub const Request = struct {
    arena: std.mem.Allocator,
    project: *const Project,
    app: *const App,
    /// The path inside the app: `/issues` for `/newsletter/issues` under `/newsletter`.
    inside: []const u8,
    http: *const http.Request,
    identity: identity_module.Identity,

    /// `GET`, `POST`, …, as HTTP writes it.
    pub fn method(request: *const Request) []const u8 {
        std.debug.assert(request.http.path().len > 0);

        const name = @tagName(request.http.method());
        const upper = request.arena.alloc(u8, name.len) catch @panic("out of memory");

        return std.ascii.upperString(upper, name);
    }

    /// The path inside the app, `/` and on, without the query: an app mounted under
    /// `/newsletter` sees `/issues` for `/newsletter/issues`.
    pub fn path(request: *const Request) []const u8 {
        std.debug.assert(request.inside.len > 0);

        return request.inside;
    }

    /// What the app's own URLs start with: `/newsletter` under that path, else nothing.
    pub fn base(request: *const Request) []const u8 {
        std.debug.assert(request.inside.len > 0);

        return request.app.base();
    }

    pub fn starts_with(request: *const Request, prefix: []const u8) bool {
        std.debug.assert(prefix.len > 0);

        return std.mem.startsWith(u8, request.inside, prefix);
    }

    /// A query parameter, decoded; null when the query has none.
    pub fn query(request: *const Request, name: []const u8) ?[]const u8 {
        std.debug.assert(name.len > 0);

        return http.Form.query_param(request.arena, request.http.query(), name);
    }

    pub fn header(request: *const Request, name: []const u8) ?[]const u8 {
        std.debug.assert(name.len > 0);

        return request.http.header(name);
    }

    pub fn cookie(request: *const Request, name: []const u8) ?[]const u8 {
        std.debug.assert(name.len > 0);

        const text = request.http.header("cookie") orelse return null;

        return identity_module.cookie_value(text, name);
    }

    /// The host asked for, with its port when it has one.
    pub fn host(request: *const Request) []const u8 {
        std.debug.assert(request.http.path().len > 0);

        return request.http.header("host") orelse "";
    }

    /// The signed-in visitor; null for anyone else.
    pub fn user(request: *const Request) ?User {
        std.debug.assert(request.http.path().len > 0);

        const signed_in = switch (request.identity.caller) {
            .user => |found| found,
            else => return null,
        };

        return .{
            .id = signed_in.id,
            .email = request.identity.email,
            .display_name = request.identity.display_name,
            .roles = signed_in.roles,
        };
    }

    /// The signed-in visitor's custom field (`<group>.<field>`) as text, as templates read
    /// it with `Publr.request.userField`; null when nobody is signed in or it is empty.
    pub fn user_field(request: *const Request, field: []const u8) !?[]const u8 {
        std.debug.assert(field.len > 0);

        const signed_in = request.user() orelse return null;

        return context_module.user_field_of(request.project, request.arena, signed_in.id, field);
    }

    /// Runs an operation as the visitor, through the same pipeline and policies as the API:
    /// middleware can do nothing its visitor could not.
    pub fn call(
        request: *const Request,
        comptime Operation: type,
        in: Operation.In,
    ) sdk.Error!Operation.Out {
        std.debug.assert(Operation.name.len > 0);

        var ctx = identity_module.context(request.project, request.arena, request.identity.caller);

        return registry.SDK.dispatch(&ctx, Operation, in);
    }

    /// Text formatted into the request's memory.
    pub fn print(request: *const Request, comptime format: []const u8, args: anytype) []const u8 {
        std.debug.assert(format.len > 0);

        return std.fmt.allocPrint(request.arena, format, args) catch @panic("out of memory");
    }

    /// `303 See Other` to `location`: a path on this site or any URL.
    pub fn redirect(request: *const Request, location: []const u8) Response {
        std.debug.assert(request.http.path().len > 0);

        return .{ .status = 303, .location = location };
    }

    /// This page instead, with this status.
    pub fn respond(request: *const Request, status: u16, body: []const u8) Response {
        std.debug.assert(request.http.path().len > 0);

        return .{ .status = status, .body = body };
    }

    /// `value` as JSON, `200 OK`.
    pub fn json(request: *const Request, value: anytype) Response {
        std.debug.assert(request.http.path().len > 0);

        const text = std.json.Stringify.valueAlloc(request.arena, value, .{}) catch
            @panic("out of memory");

        return .{ .status = 200, .content_type = "application/json", .body = text };
    }
};

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
    var request: Request = .{
        .arena = arena,
        .project = project,
        .app = app,
        .inside = inside,
        .http = incoming,
        .identity = context_module.identify(project, app, arena, incoming),
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

    // Middleware answers per request, often per visitor: no shared cache keeps it.
    try response.set_header("Cache-Control", "private, no-store");

    if (redirecting) {
        return response.redirect(status, given.location);
    }

    try response.set_body(status, given.content_type, given.body);
}

test "an answer is written as given, and a redirect must name where" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var response: http.Response = .{ .arena = arena_state.allocator() };

    try write(&response, .{ .status = 303, .location = "https://ada.publr.app/" });
    try std.testing.expectEqual(http.Status.see_other, response.status);
    try std.testing.expectEqualStrings("https://ada.publr.app/", response.header("Location").?);
    try std.testing.expectEqualStrings("private, no-store", response.header("Cache-Control").?);

    var page: http.Response = .{ .arena = arena_state.allocator() };

    try write(&page, .{ .status = 402, .body = "<p>Members only</p>" });
    try std.testing.expectEqual(@as(u16, 402), page.status.code());

    var broken: http.Response = .{ .arena = arena_state.allocator() };

    try std.testing.expectError(error.Invalid, write(&broken, .{ .status = 303 }));
    try std.testing.expectError(error.Invalid, write(&broken, .{ .status = 200, .location = "/" }));
    try std.testing.expectError(error.Invalid, write(&broken, .{ .status = 299 }));
}
