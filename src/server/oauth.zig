//! This Publr as an OAuth server for MCP clients, so a tool adds it by its address alone:
//!
//! - `/.well-known/oauth-protected-resource` and `/.well-known/oauth-authorization-server`:
//!   where `/mcp`'s tokens come from, and how.
//! - `POST /oauth/register`: anyone registers a client (RFC 7591); its id carries it.
//! - `GET /oauth/authorize`: the client's request, then the admin's approve page.
//! - `POST /oauth/token`: the code the client was sent back with, and its verifier, for the
//!   device's token.

const std = @import("std");
const credentials = @import("credentials.zig");
const http = @import("../lib/http.zig");
const registry = @import("registry.zig");
const oauth_model = @import("../model/oauth.zig");
const identity_module = @import("../adapters/rest/identity.zig");
const oauth = @import("../operations/device/oauth.zig");
const Project = @import("project.zig").Project;

const Request = http.Request;
const Response = http.Response;
const Context = http.Context;
const Form = http.Form;

pub const resource_route = "/.well-known/oauth-protected-resource";
pub const resource_mcp_route = resource_route ++ "/mcp";
pub const server_route = "/.well-known/oauth-authorization-server";
pub const register_route = "/oauth/register";
pub const authorize_route = "/oauth/authorize";
pub const token_route = "/oauth/token";
/// Where MCP clients are answered (`mcp.zig`).
pub const mcp_path = "/mcp";
pub const body_bytes_max: u32 = 16 << 10;
/// What a client that gives no name is called on the approve page.
const unnamed = "An MCP client";

/// Where this Publr's admin answers: its own host when it has one, else the one asked, with
/// the path its addresses carry.
pub fn base_of(project: *const Project, request: *const Request, arena: std.mem.Allocator) ![]u8 {
    std.debug.assert(request.path().len > 0);

    // A tool asking at a loopback address is answered there: over plain http it may send
    // tokens only to one, and `admin.localhost` is not.
    const asked_at_loopback = credentials.host_is_loopback(request.header("host") orelse "");

    if (project.split() and !asked_at_loopback) {
        return std.fmt.allocPrint(arena, "{s}{s}", .{ project.admin_origin, project.admin_path() });
    }

    const host = request.header("host") orelse "localhost";
    const forwarded = request.header("x-forwarded-proto") orelse "http";
    const scheme = if (std.mem.eql(u8, forwarded, "https")) "https" else "http";

    return std.fmt.allocPrint(arena, "{s}://{s}{s}", .{ scheme, host, project.admin_path() });
}

/// The address to give a tool: `base_of`, on this machine at `localhost` rather than
/// `<name>.localhost`, where a tool would refuse to sign in over plain http.
pub fn tool_base_of(
    project: *const Project,
    request: *const Request,
    arena: std.mem.Allocator,
) ![]const u8 {
    std.debug.assert(request.path().len > 0);

    return loopback_of(arena, try base_of(project, request, arena));
}

/// `http://admin.localhost:8170/x` as `http://localhost:8170/x`; any other address as it is.
fn loopback_of(arena: std.mem.Allocator, base: []const u8) ![]const u8 {
    std.debug.assert(base.len > 0);

    const scheme = "http://";

    if (!std.mem.startsWith(u8, base, scheme)) {
        return base;
    }

    const rest = base[scheme.len..];
    const name_end = std.mem.indexOfAny(u8, rest, ":/") orelse rest.len;

    if (!std.mem.endsWith(u8, rest[0..name_end], ".localhost")) {
        return base;
    }

    return std.fmt.allocPrint(arena, "{s}localhost{s}", .{ scheme, rest[name_end..] });
}

test "a tool is given localhost, never a name under it" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    try std.testing.expectEqualStrings(
        "http://localhost:8170",
        try loopback_of(arena, "http://admin.localhost:8170"),
    );
    try std.testing.expectEqualStrings(
        "https://admin.localhost",
        try loopback_of(arena, "https://admin.localhost"),
    );
    try std.testing.expectEqualStrings(
        "https://ada--admin.publr.app",
        try loopback_of(arena, "https://ada--admin.publr.app"),
    );
}

/// `/.well-known/oauth-protected-resource`: `/mcp`, and who issues its tokens.
pub fn resource(request: *Request, response: *Response, ctx: *Context) http.Error!void {
    std.debug.assert(ctx.user_data != null);
    std.debug.assert(request.path().len > 0);

    const base = try base_of(Project.of(ctx), request, ctx.arena);

    try response.json(.ok, .{
        .resource = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ base, mcp_path }),
        .authorization_servers = &[_][]const u8{base},
        .bearer_methods_supported = &[_][]const u8{"header"},
    });
}

/// `/.well-known/oauth-authorization-server`: the code flow with PKCE, for public clients.
pub fn server(request: *Request, response: *Response, ctx: *Context) http.Error!void {
    std.debug.assert(ctx.user_data != null);
    std.debug.assert(request.path().len > 0);

    const arena = ctx.arena;
    const base = try base_of(Project.of(ctx), request, arena);
    const authorize_at = try std.fmt.allocPrint(arena, "{s}{s}", .{ base, authorize_route });
    const token_at = try std.fmt.allocPrint(arena, "{s}{s}", .{ base, token_route });
    const register_at = try std.fmt.allocPrint(arena, "{s}{s}", .{ base, register_route });

    try response.json(.ok, .{
        .issuer = base,
        .authorization_endpoint = authorize_at,
        .token_endpoint = token_at,
        .registration_endpoint = register_at,
        .response_types_supported = &[_][]const u8{"code"},
        .grant_types_supported = &[_][]const u8{"authorization_code"},
        .code_challenge_methods_supported = &[_][]const u8{"S256"},
        .token_endpoint_auth_methods_supported = &[_][]const u8{"none"},
        .scopes_supported = &[_][]const u8{ "read", "write", "production", "publish" },
    });
}

const Registration = struct {
    client_name: []const u8 = unnamed,
    redirect_uris: []const []const u8 = &.{},
};

/// `POST /oauth/register`: a client with a name and the addresses it may be sent back to.
pub fn register(request: *Request, response: *Response, ctx: *Context) http.Error!void {
    std.debug.assert(ctx.user_data != null);
    std.debug.assert(request.method() == .post);

    if (request.body.len > body_bytes_max) {
        return failure(response, .payload_too_large, "invalid_client_metadata");
    }

    const asked = std.json.parseFromSliceLeaky(Registration, ctx.arena, request.body, .{
        .ignore_unknown_fields = true,
    }) catch return failure(response, .bad_request, "invalid_client_metadata");
    const name = if (named(asked.client_name)) asked.client_name else unnamed;
    const client: oauth_model.Client = .{
        .name = name,
        .redirect_uris = asked.redirect_uris,
    };
    const client_id = oauth_model.client_id_of(ctx.arena, client) catch |err| switch (err) {
        error.Invalid => return failure(response, .bad_request, "invalid_redirect_uri"),
        error.OutOfMemory => return error.OutOfMemory,
    };

    try response.json(.created, .{
        .client_id = client_id,
        .client_name = name,
        .redirect_uris = asked.redirect_uris,
        .token_endpoint_auth_method = "none",
        .grant_types = &[_][]const u8{"authorization_code"},
        .response_types = &[_][]const u8{"code"},
    });
}

fn named(name: []const u8) bool {
    std.debug.assert(unnamed.len > 0);

    return @import("../model/device.zig").valid_name(name) and
        std.mem.indexOfScalar(u8, name, '\n') == null;
}

/// `GET /oauth/authorize`: the client's request kept, then the person to the approve page,
/// which signs them in first. A client or return address that does not check out is told
/// so here and never followed.
pub fn authorize(request: *Request, response: *Response, ctx: *Context) http.Error!void {
    std.debug.assert(ctx.user_data != null);
    std.debug.assert(request.path().len > 0);

    const project = Project.of(ctx);
    const arena = ctx.arena;
    const query = request.query();
    const field = struct {
        fn of(allocator: std.mem.Allocator, text: []const u8, name: []const u8) []const u8 {
            return Form.query_param(allocator, text, name) orelse "";
        }
    }.of;
    const code_flow = std.mem.eql(u8, field(arena, query, "response_type"), "code") and
        std.mem.eql(u8, field(arena, query, "code_challenge_method"), "S256");

    try response.set_header("Cache-Control", "no-store");

    if (!code_flow) {
        return response.text(.bad_request, "This client asked in a way Publr does not " ++
            "answer: the authorization code flow with PKCE (S256) is required.\n");
    }

    const scope = field(arena, query, "scope");
    var sdk_ctx = identity_module.request_context(project, request, arena, .anonymous);
    const asked = registry.SDK.dispatch(&sdk_ctx, oauth.Authorize, .{
        .client_id = field(arena, query, "client_id"),
        .redirect_uri = field(arena, query, "redirect_uri"),
        .code_challenge = field(arena, query, "code_challenge"),
        .state = field(arena, query, "state"),
        .scope = if (scope.len > 0) widest(scope) else "publish",
    }) catch {
        return response.text(.bad_request, "This client is not known here, or asked to be " ++
            "sent somewhere it did not register. Add Publr to it again.\n");
    };
    // The base path, if any, is put on by `base.zig`.
    try response.redirect(.see_other, asked.approve_path);
}

/// The widest of the scopes a client lists (`read write`); the person may give less.
fn widest(scopes: []const u8) []const u8 {
    std.debug.assert(scopes.len > 0);

    const order = [_][]const u8{ "publish", "production", "write", "read" };

    for (order) |scope| {
        var words = std.mem.tokenizeScalar(u8, scopes, ' ');

        while (words.next()) |word| {
            if (std.mem.eql(u8, word, scope)) {
                return scope;
            }
        }
    }

    return "publish";
}

/// `POST /oauth/token`: the code and its verifier, traded once for the device's token.
pub fn token(request: *Request, response: *Response, ctx: *Context) http.Error!void {
    std.debug.assert(ctx.user_data != null);
    std.debug.assert(request.method() == .post);

    try response.set_header("Cache-Control", "no-store");

    if (request.body.len > body_bytes_max) {
        return failure(response, .payload_too_large, "invalid_request");
    }

    const arena = ctx.arena;
    const body = request.body;
    const grant = Form.query_param(arena, body, "grant_type") orelse "";

    if (!std.mem.eql(u8, grant, "authorization_code")) {
        return failure(response, .bad_request, "unsupported_grant_type");
    }

    var sdk_ctx = identity_module.request_context(Project.of(ctx), request, arena, .anonymous);
    const traded = registry.SDK.dispatch(&sdk_ctx, oauth.Exchange, .{
        .code = Form.query_param(arena, body, "code") orelse "",
        .code_verifier = Form.query_param(arena, body, "code_verifier") orelse "",
        .client_id = Form.query_param(arena, body, "client_id") orelse "",
        .redirect_uri = Form.query_param(arena, body, "redirect_uri") orelse "",
    }) catch return failure(response, .bad_request, "invalid_grant");

    try response.json(.ok, .{
        .access_token = traded.token,
        .token_type = "Bearer",
        .scope = traded.scope,
    });
}

fn failure(response: *Response, status: http.Status, code: []const u8) http.Error!void {
    std.debug.assert(code.len > 0);

    try response.json(status, .{
        .@"error" = code,
    });
}

test "a client's widest scope is asked; none known asks for all" {
    try std.testing.expectEqualStrings("production", widest("read production"));
    try std.testing.expectEqualStrings("write", widest("openid write"));
    try std.testing.expectEqualStrings("read", widest("read"));
    try std.testing.expectEqualStrings("publish", widest("mcp"));
}

test "a tool adds Publr by its address: registers, is approved, trades its code, calls /mcp" {
    const sdk = @import("../sdk.zig");
    const admin = @import("../adapters/admin.zig");

    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var flow: admin.Flow = .{
        .inner = undefined,
    };
    flow.inner.init(.{
        .connection = &harness.fixture.connection,
        .auth = &harness.auth,
        .io = std.testing.io,
    }, arena);

    const setup_body = "email=ada%40example.com&display_name=Ada&password=correct+horse+battery";
    _ = try flow.call("POST", "/admin/setup", setup_body);

    const registration = "{\"client_name\":\"Cursor\"," ++
        "\"redirect_uris\":[\"http://localhost:8787/callback\"]}";
    const registered = try flow.call("POST", register_route, registration);
    try std.testing.expectEqual(@as(u16, 201), registered.status.code());

    const Registered = struct {
        client_id: []const u8,
    };
    const client = try std.json.parseFromSliceLeaky(Registered, arena, registered.body, .{
        .ignore_unknown_fields = true,
    });
    const elsewhere_only = "{\"redirect_uris\":[\"http://evil.com/\"]}";
    const evil = try flow.call("POST", register_route, elsewhere_only);
    try std.testing.expectEqual(@as(u16, 400), evil.status.code());

    const callback = "http%3A%2F%2Flocalhost%3A8787%2Fcallback";
    const challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM";
    const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
    const asked = try flow.call("GET", try std.fmt.allocPrint(arena, "{s}?response_type=code&" ++
        "client_id={s}&redirect_uri={s}&code_challenge={s}&code_challenge_method=S256&" ++
        "state=a%20b", .{ authorize_route, client.client_id, callback, challenge }), "");
    const approve_path = asked.header("Location").?;
    try std.testing.expect(std.mem.startsWith(u8, approve_path, "/admin/settings/devices/approve"));

    const unregistered = try std.fmt.allocPrint(arena, "{s}?response_type=code&" ++
        "client_id={s}&redirect_uri=http%3A%2F%2Flocalhost%3A9%2Fx&code_challenge={s}&" ++
        "code_challenge_method=S256", .{ authorize_route, client.client_id, challenge });
    const elsewhere = try flow.call("GET", unregistered, "");
    try std.testing.expectEqual(@as(u16, 400), elsewhere.status.code());

    const page = try flow.call("GET", approve_path, "");
    try std.testing.expect(std.mem.indexOf(u8, page.body, "localhost:8787/callback") != null);

    const user_code = approve_path[std.mem.indexOf(u8, approve_path, "code=").? + 5 ..];
    const decided = try flow.call("POST", "/admin/settings/devices/approve", try std.fmt.allocPrint(
        arena,
        "csrf={s}&code={s}&decision=approve&access=write",
        .{ flow.csrf_of(page.body), user_code },
    ));
    const back = decided.header("Location").?;
    try std.testing.expect(std.mem.startsWith(u8, back, "http://localhost:8787/callback?code="));
    try std.testing.expect(std.mem.endsWith(u8, back, "&state=a%20b"));

    const code = back["http://localhost:8787/callback?code=".len..][0..64];
    const trade = "grant_type=authorization_code&code={s}&code_verifier={s}&client_id={s}&" ++
        "redirect_uri=" ++ callback;
    const wrong = try flow.call("POST", token_route, try std.fmt.allocPrint(arena, trade, .{
        code,
        verifier[1..] ++ "x",
        client.client_id,
    }));
    try std.testing.expectEqual(@as(u16, 400), wrong.status.code());

    const right_body = try std.fmt.allocPrint(arena, trade, .{ code, verifier, client.client_id });
    const right = try flow.call("POST", token_route, right_body);
    try std.testing.expectEqual(@as(u16, 200), right.status.code());

    const again = try flow.call("POST", token_route, right_body);
    try std.testing.expectEqual(@as(u16, 400), again.status.code());

    const Token = struct {
        access_token: []const u8,
        scope: []const u8,
    };
    const traded = try std.json.parseFromSliceLeaky(Token, arena, right.body, .{
        .ignore_unknown_fields = true,
    });
    try std.testing.expectEqualStrings("write", traded.scope);

    const listing = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":" ++
        "{\"name\":\"run\",\"arguments\":{\"args\":[\"content_type\",\"list\"]}}}";
    const anonymous = try flow.inner.call(
        "POST /mcp HTTP/1.1\r\nHost: h\r\nContent-Length: 0\r\n\r\n",
        listing,
    );
    try std.testing.expectEqual(@as(u16, 401), anonymous.status.code());
    try std.testing.expect(std.mem.indexOf(
        u8,
        anonymous.header("WWW-Authenticate").?,
        resource_route,
    ) != null);

    const signed = try flow.inner.call(try std.fmt.allocPrint(
        arena,
        "POST /mcp HTTP/1.1\r\nHost: h\r\nAuthorization: Bearer {s}\r\nContent-Length: 0\r\n\r\n",
        .{traded.access_token},
    ), listing);
    try std.testing.expectEqual(@as(u16, 200), signed.status.code());
    try std.testing.expect(std.mem.indexOf(u8, signed.body, "\"isError\":false") != null);
}
