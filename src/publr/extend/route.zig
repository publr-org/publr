//! HTTP routes a built-in plugin answers (`host.route`), each under a prefix it owns,
//! `/admin/<own>`, `/api/<own>` or `/auth/<own>`, and the commands the CLI beside a running
//! server sends it with the operator key (`host.operator_command`). A handler is given the
//! request, the response it fills and the route's context; what lies behind them is
//! Publr's own server.
const std = @import("std");
const http = @import("../../lib/http.zig");
const Ctx = @import("../ctx.zig").Ctx;

pub const Method = enum { get, post };

/// How a response ends.
pub const Status = std.http.Status;

/// How a handler fails: the response could not be written.
pub const Error = error{
    TooManyHeaders,
    HeaderTooLarge,
    InvalidHeader,
    BodyTooLarge,
    OutOfMemory,
    WriteFailed,
};

pub const Handler = *const fn (*Request, *Response, *Context) Error!void;

pub const Route = struct {
    method: Method = .get,
    /// `/api/<own>/...`; `:name` segments after the prefix are parameters (`param`).
    path: []const u8,
    /// Answers once the whole body is in, at most a request's size.
    handler: ?Handler = null,
    /// Or, for a POST: takes the body as it arrives. A route has one or the other.
    stream: ?*const Stream = null,
};

/// A POST whose body is taken as it arrives, a piece at a time, so a body larger than a
/// request may be (an upload) never sits in memory: `open` once the head is in, `write`
/// for each piece, then `finish` to answer, or `abort` when the client goes away. The state
/// `open` answers is the stream's to free in `finish` and `abort`.
pub const Stream = struct {
    /// The largest body taken; a longer declared one is refused with 413.
    bytes_max: u64,
    open: *const fn (*Request, *Response, *Context) anyerror!?*anyopaque,
    write: *const fn (state: *anyopaque, bytes: []const u8) anyerror!void,
    finish: *const fn (state: *anyopaque, *Response, *Context) anyerror!void,
    abort: *const fn (state: *anyopaque) void,
};

/// What the CLI next to a running server asks it, with the server's operator key:
/// `POST /_publr/<plugin>/<name>`. Only a process of this user on this machine has the key.
pub const OperatorCommand = struct {
    name: []const u8,
    handler: Handler,
};

fn Behind(comptime Pointer: type, comptime Core: type) type {
    return if (@typeInfo(Pointer).pointer.attrs.@"const") *const Core else *Core;
}

fn behind(comptime Core: type, given: anytype) Behind(@TypeOf(given), Core) {
    return @ptrCast(@alignCast(given));
}

/// The request as it came.
pub const Request = opaque {
    pub fn method(request: *const Request) std.http.Method {
        std.debug.assert(request.path().len > 0);

        return switch (behind(http.Request, request).method()) {
            .get => .GET,
            .head => .HEAD,
            .post => .POST,
            .put => .PUT,
            .patch => .PATCH,
            .delete => .DELETE,
            .options => .OPTIONS,
        };
    }

    /// The path, without the query.
    pub fn path(request: *const Request) []const u8 {
        return behind(http.Request, request).path();
    }

    /// The query, without its `?`.
    pub fn query(request: *const Request) []const u8 {
        return behind(http.Request, request).query();
    }

    /// One query parameter, decoded into `arena`; null when the query has none.
    pub fn query_param(
        request: *const Request,
        arena: std.mem.Allocator,
        name: []const u8,
    ) ?[]const u8 {
        std.debug.assert(name.len > 0);

        return http.Form.query_param(arena, request.query(), name);
    }

    pub fn header(request: *const Request, name: []const u8) ?[]const u8 {
        return behind(http.Request, request).header(name);
    }

    /// A `:name` segment of the route's path.
    pub fn param(request: *const Request, name: []const u8) ?[]const u8 {
        return behind(http.Request, request).param(name);
    }

    /// The body, as sent.
    pub fn body(request: *const Request) []const u8 {
        return behind(http.Request, request).body;
    }

    /// One field of a urlencoded form body, decoded into `arena`; null when it has none.
    pub fn form_field(
        request: *const Request,
        arena: std.mem.Allocator,
        name: []const u8,
    ) ?[]const u8 {
        std.debug.assert(name.len > 0);

        return http.Form.query_param(arena, request.body(), name);
    }
};

fn status_of(status: Status) http.Status {
    return std.enums.fromInt(http.Status, @backingInt(status)) orelse .internal_server_error;
}

/// The response a handler fills.
pub const Response = opaque {
    pub fn text(response: *Response, status: Status, body: []const u8) Error!void {
        return behind(http.Response, response).text(status_of(status), body);
    }

    pub fn html(response: *Response, status: Status, body: []const u8) Error!void {
        return behind(http.Response, response).html(status_of(status), body);
    }

    /// `value` written as JSON.
    pub fn json(response: *Response, status: Status, value: anytype) Error!void {
        return behind(http.Response, response).json(status_of(status), value);
    }

    pub fn redirect(response: *Response, status: Status, location: []const u8) Error!void {
        return behind(http.Response, response).redirect(status_of(status), location);
    }

    /// `body` with its type, as given.
    pub fn set_body(
        response: *Response,
        status: Status,
        content_type: []const u8,
        body: []const u8,
    ) Error!void {
        return behind(http.Response, response).set_body(status_of(status), content_type, body);
    }

    /// The header `name`, in place of one set before.
    pub fn set_header(response: *Response, name: []const u8, value: []const u8) Error!void {
        return behind(http.Response, response).set_header(name, value);
    }

    /// Another header `name`, beside those set before (`Set-Cookie`).
    pub fn add_header(response: *Response, name: []const u8, value: []const u8) Error!void {
        return behind(http.Response, response).add_header(name, value);
    }
};

/// The route's context: the request's memory and the server around it.
pub const Context = opaque {
    /// Memory freed when the request ends.
    pub fn arena(context: *const Context) std.mem.Allocator {
        return behind(http.Context, context).arena;
    }

    /// For calls to elsewhere, made while the request waits.
    pub fn io(context: *const Context) std.Io {
        return behind(http.Context, context).io;
    }

    /// Whoever sent the request, as a `publr.Ctx` to call operations as them, the way the
    /// REST API does: a write must come from this site with the session's CSRF token. Null
    /// when it does not; the refusal is already written.
    pub fn caller(context: *Context, request: *const Request, response: *Response) Error!?*Ctx {
        return @import("../../server/plugin_routes.zig").public.caller(context, request, response);
    }

    /// The state the built-in plugin `Plugin` keeps for the life of the process.
    pub fn state(context: *const Context, comptime Plugin: type) *State(Plugin) {
        return @import("../../server/plugin_routes.zig").public.state(context, Plugin);
    }

    /// Signs the request's sender in to the session `token` names, until `expires_at_ms`:
    /// what a sign-in of the plugin's own sets, the way core's sign-in does.
    pub fn set_session(
        context: *Context,
        request: *const Request,
        response: *Response,
        token: []const u8,
        expires_at_ms: i64,
    ) Error!void {
        return @import("../../server/plugin_routes.zig").public.set_session(
            context,
            request,
            response,
            token,
            expires_at_ms,
        );
    }
};

fn State(comptime Plugin: type) type {
    return @import("../../server/plugin_states.zig").StateOf(Plugin);
}
