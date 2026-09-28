//! The sign-in endpoints: `/api/auth/sign-in`, `sign-out`, `set-password`, `session`.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const sign_in_operations = @import("../../operations/sign_in.zig");
const sign_on_operations = @import("../../operations/sign_on.zig");
const user_operations = @import("../../operations/user.zig");
const csrf = @import("../../lib/auth.zig").csrf;
const identity_module = @import("identity.zig");
const http = @import("../../lib/http.zig");
const Project = @import("../../server/project.zig").Project;

const Error = http.Error;
const Request = http.Request;
const Response = http.Response;
const Context = http.Context;
const identify = identity_module.identify;
const guard = identity_module.guard;
const context = identity_module.context;
const set_session_cookie = identity_module.set_session_cookie;
const clear_session_cookie = identity_module.clear_session_cookie;

pub const body_bytes_max: u32 = 16 << 10;

pub fn sign_in(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    const project = Project.of(ctx);
    const identity = identify(request, ctx.arena, project);

    if (!try guard(request, response, project, &identity)) {
        return;
    }

    const in = parse_body(sign_in_operations.SignIn.In, ctx.arena, request.body) orelse {
        return response.json(.bad_request, .{ .@"error" = "invalid_body" });
    };
    var sdk_ctx = context(project, ctx.arena, .anonymous);
    const out = registry.SDK.dispatch(&sdk_ctx, sign_in_operations.SignIn, in) catch |err| {
        return respond_error(response, err, &sdk_ctx);
    };

    const now_ms = sdk_ctx.now_ms;

    const expires_at = out.expires_at;

    try set_session_cookie(project, request, response, ctx.arena, out.token, expires_at, now_ms);

    var csrf_buffer: [csrf.token_len]u8 = undefined;
    const session_id = out.token[0..sign_in_operations.session_id_len];

    try response.json(.ok, .{
        .user_id = out.user_id,
        .expires_at = out.expires_at,
        .csrf = csrf.token(project.auth.secret, session_id, &csrf_buffer),
    });
}

/// `/auth/sign-on`: a token from the trusted issuer, in the query (a redirect back) or a
/// posted form (a frame the dashboard fills), becomes the session cookie; then on to
/// `return`, a path on this site. No same-origin check: the issuer is another origin, and
/// the token itself is the credential. A token refused sends you to the login form.
pub fn sign_on(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(ctx.user_data != null);
    std.debug.assert(request.path().len > 0);

    const project = Project.of(ctx);
    const source = if (request.method() == .post) request.body else request.query();
    const token = http.Form.query_param(ctx.arena, source, "token") orelse "";
    const wanted = http.Form.query_param(ctx.arena, source, "return") orelse "/admin";
    const back = if (local_path(wanted)) wanted else "/admin";
    var sdk_ctx = context(project, ctx.arena, .anonymous);
    const redeem = sign_on_operations.Redeem;
    const out = registry.SDK.dispatch(&sdk_ctx, redeem, .{ .token = token }) catch {
        try response.set_header("Cache-Control", "no-store");
        return response.redirect(.see_other, "/admin/login?sign_on=refused");
    };

    const now_ms = sdk_ctx.now_ms;

    const expires_at = out.expires_at;

    try set_session_cookie(project, request, response, ctx.arena, out.token, expires_at, now_ms);
    try response.set_header("Cache-Control", "no-store");
    try response.redirect(.see_other, back);
}

/// A path on this site: one leading slash, not `//` or `/\` (another host), no control
/// characters.
fn local_path(path: []const u8) bool {
    std.debug.assert(path.len <= 1 << 16);

    if (path.len == 0 or path[0] != '/') {
        return false;
    }

    if (path.len > 1 and (path[1] == '/' or path[1] == '\\')) {
        return false;
    }

    for (path) |char| {
        if (char < 0x20 or char == 0x7f) {
            return false;
        }
    }

    return true;
}

pub fn set_password(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    const project = Project.of(ctx);
    const identity = identify(request, ctx.arena, project);

    if (!try guard(request, response, project, &identity)) {
        return;
    }

    const in = parse_body(user_operations.SetPassword.In, ctx.arena, request.body) orelse {
        return response.json(.bad_request, .{ .@"error" = "invalid_body" });
    };
    var sdk_ctx = context(project, ctx.arena, .anonymous);
    const out = registry.SDK.dispatch(&sdk_ctx, user_operations.SetPassword, in) catch |err| {
        return respond_error(response, err, &sdk_ctx);
    };

    try response.json(.ok, .{ .user_id = out.user_id });
}

pub fn sign_out(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    const project = Project.of(ctx);
    const identity = identify(request, ctx.arena, project);

    if (!try guard(request, response, project, &identity)) {
        return;
    }

    if (identity.token) |token| {
        var sdk_ctx = context(project, ctx.arena, identity.caller);
        const sign_out_operation = sign_in_operations.SignOut;
        _ = registry.SDK.dispatch(&sdk_ctx, sign_out_operation, .{ .token = token }) catch |err| {
            return respond_error(response, err, &sdk_ctx);
        };
    }

    try clear_session_cookie(project, request, response, ctx.arena);
    try response.json(.ok, .{ .signed_out = identity.token != null });
}

pub fn whoami(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    const project = Project.of(ctx);
    const identity = identify(request, ctx.arena, project);
    var csrf_buffer: [csrf.token_len]u8 = undefined;

    const now_ms = sdk.context.wall_clock_ms(project.io);

    identity_module.repair_hint(project, request, response, ctx.arena, &identity, now_ms);

    try response.json(.ok, .{
        .authenticated = identity.session != null,
        .user_id = identity.caller.user_id(),
        .roles = identity.caller.roles(),
        .csrf = identity.csrf_token(project, &csrf_buffer),
    });
}

fn parse_body(comptime In: type, arena: std.mem.Allocator, body: []const u8) ?In {
    std.debug.assert(@typeInfo(In) == .@"struct");
    std.debug.assert(body_bytes_max > 0);

    if (body.len == 0 or body.len > body_bytes_max) {
        return null;
    }

    const options: std.json.ParseOptions = .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    };

    return @import("../../lib/json.zig").parse(In, arena, body, options) catch null;
}

/// The operation's error as JSON: `{ "error": "<name>" }` with a matching status. A
/// plugin's own failure (`error.Failed`) answers with its declared name, status and message.
pub fn respond_error(response: *Response, err: sdk.Error, ctx: *const sdk.Ctx) Error!void {
    std.debug.assert(@errorName(err).len > 0);
    std.debug.assert(response.headers_len <= 32);

    if (err == error.Failed) {
        const failure = ctx.failure orelse {
            return response.json(.internal_server_error, .{ .@"error" = "Failed" });
        };
        const declared = std.enums.fromInt(http.Status, failure.status) orelse
            .unprocessable_content;

        return response.json(declared, .{
            .@"error" = failure.name,
            .message = failure.message,
        });
    }

    const status: http.Status = switch (err) {
        error.BadCredentials => .unauthorized,
        error.Throttled => .too_many_requests,
        error.Failed => unreachable,
        error.Unavailable => .service_unavailable,
        error.Denied => .forbidden,
        error.Invalid => .unprocessable_content,
        error.NotFound => .not_found,
        error.Conflict => .conflict,
        error.Vetoed => .forbidden,
        error.InvalidationFailed,
        error.OutOfMemory,
        error.Busy,
        error.Constraint,
        error.ReadOnly,
        error.Sqlite,
        => .internal_server_error,
    };

    try response.json(status, .{ .@"error" = @errorName(err) });
}

const routes = @import("../../server/routes.zig");

test "a plugin's failure answers with its declared status, name and message" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.anonymous);
    const unverified: sdk.operation.Failure = .{
        .name = "Unverified",
        .status = 403,
        .message = "Verify your email first",
    };

    try std.testing.expectError(error.Failed, @as(sdk.Error!void, ctx.fail(unverified)));

    var response: Response = .{ .arena = ctx.arena };
    try respond_error(&response, error.Failed, &ctx);
    try std.testing.expectEqual(@as(u16, 403), response.status.code());
    try std.testing.expectEqualStrings(
        "{\"error\":\"Unverified\",\"message\":\"Verify your email first\"}",
        response.body,
    );

    // Failed with nothing declared is the operation's bug: a server error, never a guess.
    var bare = harness.ctx(.anonymous);
    var unknown: Response = .{ .arena = bare.arena };
    try respond_error(&unknown, error.Failed, &bare);
    try std.testing.expectEqual(@as(u16, 500), unknown.status.code());
}

test "per-user answers are never cacheable by a shared cache, signed in or not" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var flow: routes.testing.Flow = undefined;
    flow.init(.{
        .connection = &harness.fixture.connection,
        .auth = &harness.auth,
        .io = std.testing.io,
    }, arena_state.allocator());

    var system = harness.ctx(.system);
    try user_operations.seed_admin(&system);

    const login_head = "POST /api/auth/sign-in HTTP/1.1\r\nHost: h\r\nOrigin: http://h\r\n" ++
        "Content-Length: 0\r\n\r\n";
    const login_body = "{\"email\":\"admin@example.com\",\"password\":\"correct horse battery\"}";
    const login = try flow.call(login_head, login_body);
    try std.testing.expectEqual(@as(u16, 200), login.status.code());
    const cookie = login.header("Set-Cookie").?;
    const cookie_pair = cookie[0..std.mem.indexOfScalar(u8, cookie, ';').?];

    const paths = [_][]const u8{ "/api/auth/session", "/api/health", "/admin", "/admin/settings" };

    for (paths) |path| {
        const request = try flow.head("GET {s} HTTP/1.1\r\nHost: h\r\n\r\n", .{path});
        const anonymous = try flow.call(request, "");
        const signed_in = try flow.call(try flow.head(
            "GET {s} HTTP/1.1\r\nHost: h\r\nCookie: {s}\r\n\r\n",
            .{ path, cookie_pair },
        ), "");

        for ([_]http.Response{ anonymous, signed_in }) |response| {
            const policy = response.header("Cache-Control") orelse return error.NoCachePolicy;

            try std.testing.expect(std.mem.startsWith(u8, policy, "private") or
                std.mem.eql(u8, policy, "no-store"));
        }
    }
}

test "auth over http: login sets the cookie, session reports the user, csrf guards logout" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var flow: routes.testing.Flow = undefined;
    flow.init(.{
        .connection = &harness.fixture.connection,
        .auth = &harness.auth,
        .io = std.testing.io,
    }, arena_state.allocator());

    var system = harness.ctx(.system);
    try user_operations.seed_admin(&system);

    const anonymous = try flow.call("GET /api/auth/session HTTP/1.1\r\nHost: h\r\n\r\n", "");
    try std.testing.expect(std.mem.indexOf(u8, anonymous.body, "\"authenticated\":false") != null);

    const login_head = "POST /api/auth/sign-in HTTP/1.1\r\nHost: h\r\nOrigin: http://h\r\n" ++
        "Content-Length: 0\r\n\r\n";
    const wrong_body = "{\"email\":\"admin@example.com\",\"password\":\"nope nope nope\"}";
    const wrong = try flow.call(login_head, wrong_body);
    try std.testing.expectEqual(@as(u16, 401), wrong.status.code());

    const foreign_head = "POST /api/auth/sign-in HTTP/1.1\r\nHost: h\r\nOrigin: http://evil\r\n" ++
        "Content-Length: 0\r\n\r\n";
    const foreign = try flow.call(foreign_head, "{}");
    try std.testing.expectEqual(@as(u16, 403), foreign.status.code());

    const right_body = "{\"email\":\"admin@example.com\",\"password\":\"correct horse battery\"}";
    const right = try flow.call(login_head, right_body);
    try std.testing.expectEqual(@as(u16, 200), right.status.code());
    const cookie = right.header("Set-Cookie").?;
    try std.testing.expect(std.mem.startsWith(u8, cookie, "publr_session="));
    try std.testing.expect(std.mem.indexOf(u8, cookie, "HttpOnly; SameSite=Lax") != null);
    try std.testing.expect(std.mem.indexOf(u8, cookie, "Secure") == null);

    const cookie_end = std.mem.indexOfScalar(u8, cookie, ';').?;
    const cookie_pair = cookie[0..cookie_end];
    const csrf_at = std.mem.indexOf(u8, right.body, "\"csrf\":\"").? + 8;
    const csrf_token = right.body[csrf_at .. csrf_at + csrf.token_len];

    const whoami_template = "GET /api/auth/session HTTP/1.1\r\nHost: h\r\nCookie: {s}\r\n\r\n";
    const whoami_head = try flow.head(whoami_template, .{cookie_pair});
    const me = try flow.call(whoami_head, "");
    try std.testing.expect(std.mem.indexOf(u8, me.body, "\"authenticated\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, me.body, "\"roles\":[\"admin\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, me.body, csrf_token) != null);

    const health_template = "GET /api/health HTTP/1.1\r\nHost: h\r\nCookie: {s}\r\n\r\n";
    const health_head = try flow.head(health_template, .{cookie_pair});
    const health_body = (try flow.call(health_head, "")).body;
    try std.testing.expect(std.mem.indexOf(u8, health_body, "\"caller\":\"anonymous\"") == null);

    const logout_template = "POST /api/auth/sign-out HTTP/1.1\r\nHost: h\r\nOrigin: http://h\r\n" ++
        "Cookie: {s}\r\nX-Csrf-Token: {s}\r\nContent-Length: 0\r\n\r\n";
    const no_csrf_head = try flow.head(logout_template, .{ cookie_pair, "nope" });
    const no_csrf = try flow.call(no_csrf_head, "");
    try std.testing.expectEqual(@as(u16, 403), no_csrf.status.code());

    const logout_head = try flow.head(logout_template, .{ cookie_pair, csrf_token });
    const out = try flow.call(logout_head, "");
    try std.testing.expectEqual(@as(u16, 200), out.status.code());
    try std.testing.expect(std.mem.indexOf(u8, out.header("Set-Cookie").?, "Max-Age=0") != null);

    const after = try flow.call(whoami_head, "");
    try std.testing.expect(std.mem.indexOf(u8, after.body, "\"authenticated\":false") != null);

    system.now_ms = sdk.context.wall_clock_ms(std.testing.io);
    const invited = try registry.SDK.dispatch(&system, user_operations.Create, .{
        .email = "new@example.com",
        .display_name = "New",
        .password_link = true,
    });
    const token = invited.link.?.path[user_operations.set_password_path.len + 7 ..];
    const set_head = "POST /api/auth/set-password HTTP/1.1\r\nHost: h\r\nOrigin: http://h\r\n" ++
        "Content-Length: 0\r\n\r\n";
    const set_template = "{{\"token\":\"{s}\",\"password\":\"correct horse battery\"}}";
    const set_body = try std.fmt.allocPrint(flow.arena, set_template, .{token});
    const set = try flow.call(set_head, set_body);
    try std.testing.expectEqual(@as(u16, 200), set.status.code());
    try std.testing.expectEqual(@as(u16, 404), (try flow.call(set_head, set_body)).status.code());

    const new_body = "{\"email\":\"new@example.com\",\"password\":\"correct horse battery\"}";
    const new_login = try flow.call(login_head, new_body);
    try std.testing.expectEqual(@as(u16, 200), new_login.status.code());
}
