//! Middleware: an app's `middleware.zig`, compiled in, sees every request for the app
//! before anything else does (pages, not-found pages, islands, any method) and either
//! answers it or lets it through. `/admin`, `/api`, `/auth` and the app's assets are
//! core's and never reach it. The sign-in addresses for tools (`/oauth/…`,
//! `/.well-known/oauth-…`, `/mcp`) reach it, and the app's page at that exact path, before
//! core answers them.
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
const http = @import("../lib/http.zig");
const sdk = @import("../sdk.zig");
const registry = @import("../server/registry.zig");
const identity_module = @import("../adapters/rest/identity.zig");
const context_module = @import("../adapters/apps/context.zig");
const Seen = @import("../adapters/apps/middleware.zig").Seen;

/// The answer middleware gives in the site's place.
pub const Response = struct {
    status: u16,
    /// Where a redirect goes: any URL, this site's or another's.
    location: []const u8 = "",
    content_type: []const u8 = "text/html; charset=utf-8",
    body: []const u8 = "",
    /// Headers besides the type and the cache policy: `WWW-Authenticate`, `Link`, ….
    headers: []const Header = &.{},

    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };
    pub const headers_max: u32 = 8;
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
    /// The path inside the app: `/issues` for `/newsletter/issues` under `/newsletter`.
    inside: []const u8,
    /// Publr's own: the site, the app, the request as it came and who sent it.
    seen: *const anyopaque,

    fn held(request: *const Request) *const Seen {
        return @ptrCast(@alignCast(request.seen));
    }

    /// `GET`, `POST`, …, as HTTP writes it.
    pub fn method(request: *const Request) []const u8 {
        std.debug.assert(request.held().http.path().len > 0);

        const name = @tagName(request.held().http.method());
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

        return request.held().app.base();
    }

    pub fn starts_with(request: *const Request, prefix: []const u8) bool {
        std.debug.assert(prefix.len > 0);

        return std.mem.startsWith(u8, request.inside, prefix);
    }

    /// A query parameter, decoded; null when the query has none.
    pub fn query(request: *const Request, name: []const u8) ?[]const u8 {
        std.debug.assert(name.len > 0);

        return http.Form.query_param(request.arena, request.held().http.query(), name);
    }

    pub fn header(request: *const Request, name: []const u8) ?[]const u8 {
        std.debug.assert(name.len > 0);

        return request.held().http.header(name);
    }

    pub fn cookie(request: *const Request, name: []const u8) ?[]const u8 {
        std.debug.assert(name.len > 0);

        const text = request.held().http.header("cookie") orelse return null;

        return identity_module.cookie_value(text, name);
    }

    /// The host asked for, with its port when it has one.
    pub fn host(request: *const Request) []const u8 {
        std.debug.assert(request.held().http.path().len > 0);

        return request.held().http.header("host") orelse "";
    }

    /// The signed-in visitor; null for anyone else.
    pub fn user(request: *const Request) ?User {
        std.debug.assert(request.held().http.path().len > 0);

        const signed_in = switch (request.held().identity.caller) {
            .user => |found| found,
            else => return null,
        };

        return .{
            .id = signed_in.id,
            .email = request.held().identity.email,
            .display_name = request.held().identity.display_name,
            .roles = signed_in.roles,
        };
    }

    /// The signed-in visitor's custom field (`<group>.<field>`) as text, as templates read
    /// it with `Publr.request.userField`; null when nobody is signed in or it is empty.
    pub fn user_field(request: *const Request, field: []const u8) !?[]const u8 {
        std.debug.assert(field.len > 0);

        const signed_in = request.user() orelse return null;

        const project = request.held().project;

        return context_module.user_field_of(project, request.arena, signed_in.id, field);
    }

    /// Runs an operation as the visitor, through the same pipeline and policies as the API:
    /// middleware can do nothing its visitor could not. What it creates belongs to the app.
    pub fn call(
        request: *const Request,
        comptime Operation: type,
        in: Operation.In,
    ) sdk.Error!Operation.Out {
        comptime std.debug.assert(registry.SDK.bound(Operation).name.len > 0);

        var ctx = identity_module.request_context(
            request.held().project,
            request.held().http,
            request.arena,
            request.held().identity.caller,
        );

        ctx.app = request.held().app.spec.name;
        ctx.app_plugins = request.held().app.spec.plugins;
        ctx.app_reach = request.held().app.spec.name;

        return registry.SDK.dispatch(&ctx, Operation, in);
    }

    /// Text formatted into the request's memory.
    pub fn print(request: *const Request, comptime format: []const u8, args: anytype) []const u8 {
        std.debug.assert(format.len > 0);

        return std.fmt.allocPrint(request.arena, format, args) catch @panic("out of memory");
    }

    /// `303 See Other` to `location`: a path on this site or any URL.
    pub fn redirect(request: *const Request, location: []const u8) Response {
        std.debug.assert(request.held().http.path().len > 0);

        return .{
            .status = 303,
            .location = location,
        };
    }

    /// This page instead, with this status.
    pub fn respond(request: *const Request, status: u16, body: []const u8) Response {
        std.debug.assert(request.held().http.path().len > 0);

        return .{
            .status = status,
            .body = body,
        };
    }

    /// The request's body, as sent: empty for a request with none.
    pub fn posted(request: *const Request) []const u8 {
        std.debug.assert(request.held().http.body.len <= 64 << 20);

        return request.held().http.body;
    }

    /// For calls to elsewhere (`std.http.Client`), made while the request waits.
    pub fn io(request: *const Request) std.Io {
        std.debug.assert(request.held().http.path().len > 0);

        return request.held().project.io;
    }

    /// `value` as JSON, `200 OK`.
    pub fn json(request: *const Request, value: anytype) Response {
        std.debug.assert(request.held().http.path().len > 0);

        const text = std.json.Stringify.valueAlloc(request.arena, value, .{}) catch
            @panic("out of memory");

        return .{
            .status = 200,
            .content_type = "application/json",
            .body = text,
        };
    }
};
