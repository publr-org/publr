const std = @import("std");
const sdk = @import("../sdk.zig");
const registry = @import("../server/registry.zig");
const auth_http = @import("rest/auth.zig");
const identity_module = @import("rest/identity.zig");
const http = @import("../lib/http.zig");
const Project = @import("../server/project.zig").Project;

const Error = http.Error;
const Request = http.Request;
const Response = http.Response;
const Context = http.Context;

pub const body_bytes_max: u32 = 8 << 20;
pub const query_pairs_max: u32 = 64;

pub fn register(router: *http.Router) void {
    std.debug.assert(router.routes_len > 0);

    router.post("/api/:namespace/:verb", &call);
    router.get("/api/:namespace/:verb", &call);

    std.debug.assert(router.routes_len >= 2);
}

fn call(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(ctx.user_data != null);
    std.debug.assert(request.path().len > 0);

    const project = Project.of(ctx);
    const namespace = request.param("namespace") orelse return not_found(response);
    const verb = request.param("verb") orelse return not_found(response);
    const identity = identity_module.identify(request, ctx.arena, project);
    const is_read = request.method() == .get or request.method() == .head;

    if (!is_read and !try identity_module.guard(request, response, project, &identity)) {
        return;
    }

    inline for (registry.SDK.operations) |Operation| {
        const same_namespace = std.mem.eql(
            u8,
            comptime sdk.operation.namespace(Operation.name),
            namespace,
        );
        const same_verb = std.mem.eql(u8, comptime sdk.operation.verb(Operation.name), verb);

        if (same_namespace and same_verb) {
            if (is_read and Operation.kind != .read) {
                return response.json(.method_not_allowed, .{ .@"error" = "use POST" });
            }

            return invoke(request, response, ctx, identity.caller, Operation, is_read);
        }
    }

    return invoke_runtime(request, response, ctx, identity.caller, namespace, verb, is_read);
}

/// An operation an installed plugin brings: JSON in the body, or flags in the query for a read.
fn invoke_runtime(
    request: *Request,
    response: *Response,
    ctx: *Context,
    caller: sdk.Caller,
    namespace: []const u8,
    verb: []const u8,
    is_read: bool,
) Error!void {
    std.debug.assert(namespace.len > 0);
    std.debug.assert(verb.len > 0);

    const project = Project.of(ctx);
    const sandboxed = project.sandboxed_plugins orelse return not_found(response);
    const name = std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ namespace, verb }) catch {
        return error.OutOfMemory;
    };
    const found = sandboxed.find(name) orelse return not_found(response);

    if (is_read and found.kind != .read) {
        return response.json(.method_not_allowed, .{ .@"error" = "use POST" });
    }

    const input = runtime_input(request, ctx.arena, found, is_read) orelse {
        return response.json(.bad_request, .{ .@"error" = "invalid_input" });
    };
    var sdk_ctx = identity_module.context(project, ctx.arena, caller);
    const output = registry.SDK.call_json(&sdk_ctx, name, input) catch |err| {
        return auth_http.respond_error(response, err, &sdk_ctx);
    };

    try response.set_body(.ok, "application/json", output);
}

fn runtime_input(
    request: *Request,
    arena: std.mem.Allocator,
    found: sdk.sandboxed_plugins.Operation,
    from_query: bool,
) ?[]const u8 {
    std.debug.assert(found.name.len > 0);
    std.debug.assert(query_pairs_max > 0);

    if (!from_query) {
        if (request.body.len > body_bytes_max) {
            return null;
        }

        return if (request.body.len == 0) "{}" else request.body;
    }

    var args_storage: [query_pairs_max * 2][]const u8 = undefined;
    const args = query_args(arena, request.query(), &args_storage) orelse return null;
    var problem: @import("cli.zig").Problem = .{};

    return @import("cli/sandboxed_plugins.zig").parse(arena, found, args, &problem) catch null;
}

fn invoke(
    request: *Request,
    response: *Response,
    ctx: *Context,
    caller: sdk.Caller,
    comptime Operation: type,
    from_query: bool,
) Error!void {
    std.debug.assert(ctx.user_data != null);
    std.debug.assert(Operation.name.len > 0);

    const parsed = if (from_query)
        parse_query(Operation.In, ctx.arena, request.query())
    else
        parse_body(Operation.In, ctx.arena, request.body);
    const in = parsed orelse {
        return response.json(.bad_request, .{ .@"error" = "invalid_input" });
    };
    var sdk_ctx = identity_module.context(Project.of(ctx), ctx.arena, caller);
    const out = registry.SDK.dispatch(&sdk_ctx, Operation, in) catch |err| {
        return auth_http.respond_error(response, err, &sdk_ctx);
    };

    try response.json(.ok, out);
}

fn parse_body(comptime In: type, arena: std.mem.Allocator, body: []const u8) ?In {
    std.debug.assert(@typeInfo(In) == .@"struct");
    std.debug.assert(body_bytes_max > 0);

    if (body.len > body_bytes_max) {
        return null;
    }

    const text: []const u8 = if (body.len == 0) "{}" else body;
    const options: std.json.ParseOptions = .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    };

    return @import("../lib/json.zig").parse(In, arena, text, options) catch null;
}

fn parse_query(comptime In: type, arena: std.mem.Allocator, query: []const u8) ?In {
    std.debug.assert(@typeInfo(In) == .@"struct");
    std.debug.assert(query_pairs_max > 0);

    const cli = @import("cli.zig");
    var args_storage: [query_pairs_max * 2][]const u8 = undefined;
    const args = query_args(arena, query, &args_storage) orelse return null;
    var problem: cli.Problem = .{};

    return cli.parse_in(In, arena, args, &problem, null) catch null;
}

/// A query string as flags: `a=1&b=2` is `--a 1 --b 2`.
fn query_args(
    arena: std.mem.Allocator,
    query: []const u8,
    args_storage: *[query_pairs_max * 2][]const u8,
) ?[]const []const u8 {
    std.debug.assert(args_storage.len == query_pairs_max * 2);

    var count: u32 = 0;
    var pairs = std.mem.splitScalar(u8, query, '&');

    while (pairs.next()) |pair| {
        if (pair.len == 0) {
            continue;
        }

        if (count + 2 > args_storage.len) {
            return null;
        }

        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const name = http.Form.decode(arena, pair[0..equals]) orelse return null;
        const value = http.Form.decode(
            arena,
            if (equals < pair.len) pair[equals + 1 ..] else "",
        ) orelse return null;

        args_storage[count] = std.fmt.allocPrint(arena, "--{s}", .{name}) catch return null;
        args_storage[count + 1] = value;
        count += 2;
    }

    return args_storage[0..count];
}

fn not_found(response: *Response) Error!void {
    std.debug.assert(response.headers_len <= 32);
    std.debug.assert(response.body.len == 0);

    return response.json(.not_found, .{ .@"error" = "unknown_operation" });
}

const routes = @import("../server/routes.zig");

test "rest: every operation is reachable under /api/<namespace>/<verb>, with the same rules" {
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
    system.now_ms = sdk.context.wall_clock_ms(std.testing.io);
    try @import("../operations/user.zig").seed_admin(&system);
    try @import("../operations/record.zig").fixture.post_type(&system);

    const check = try flow.call("GET /api/heartbeat/check?echo=hi HTTP/1.1\r\nHost: h\r\n\r\n", "");
    try std.testing.expectEqual(@as(u16, 200), check.status.code());
    try std.testing.expect(std.mem.indexOf(u8, check.body, "\"echo\":\"hi\"") != null);

    const unknown = try flow.call("GET /api/nope/verb HTTP/1.1\r\nHost: h\r\n\r\n", "");
    try std.testing.expectEqual(@as(u16, 404), unknown.status.code());

    const write_head = "POST /api/record/create HTTP/1.1\r\nHost: h\r\nOrigin: http://h\r\n" ++
        "Content-Length: 0\r\n\r\n";
    const doc = "{\"type\":\"post\"," ++
        "\"document\":\"{\\\"title\\\":\\\"Via REST\\\",\\\"body\\\":\\\"x\\\"}\"}";
    const denied = try flow.call(write_head, doc);
    try std.testing.expectEqual(@as(u16, 403), denied.status.code());

    const login_head = "POST /api/auth/sign-in HTTP/1.1\r\nHost: h\r\nOrigin: http://h\r\n" ++
        "Content-Length: 0\r\n\r\n";
    const signed = try flow.call(
        login_head,
        "{\"email\":\"admin@example.com\",\"password\":\"correct horse battery\"}",
    );
    const cookie = signed.header("Set-Cookie").?;
    const cookie_pair = cookie[0..std.mem.indexOfScalar(u8, cookie, ';').?];
    const csrf_at = std.mem.indexOf(u8, signed.body, "\"csrf\":\"").? + 8;
    const csrf_len = @import("../lib/auth.zig").csrf.token_len;
    const csrf_token = signed.body[csrf_at .. csrf_at + csrf_len];
    const authed_template = "POST /api/record/create HTTP/1.1\r\nHost: h\r\n" ++
        "Origin: http://h\r\nCookie: {s}\r\nX-Csrf-Token: {s}\r\nContent-Length: 0\r\n\r\n";
    const authed_head = try flow.head(authed_template, .{ cookie_pair, csrf_token });
    const created = try flow.call(authed_head, doc);
    try std.testing.expectEqual(@as(u16, 200), created.status.code());
    try std.testing.expect(std.mem.indexOf(u8, created.body, "\"slug\":\"via-rest\"") != null);

    const list_template = "GET /api/record/list?type=post HTTP/1.1\r\nHost: h\r\n" ++
        "Cookie: {s}\r\n\r\n";
    const listed = try flow.call(try flow.head(list_template, .{cookie_pair}), "");
    try std.testing.expect(std.mem.indexOf(u8, listed.body, "Via REST") != null);

    const anon_list = try flow.call(
        "GET /api/record/list?type=post HTTP/1.1\r\nHost: h\r\n\r\n",
        "",
    );
    try std.testing.expect(std.mem.indexOf(u8, anon_list.body, "Via REST") == null);

    const wrong_method = try flow.call(
        "GET /api/record/create?type=post HTTP/1.1\r\nHost: h\r\n\r\n",
        "",
    );
    try std.testing.expectEqual(@as(u16, 405), wrong_method.status.code());

    // The session without its signed-in hint (removed outside Publr): the hint comes back;
    // with the hint there, nothing is set.
    const session_template = "GET /api/auth/session HTTP/1.1\r\nHost: h\r\nCookie: {s}\r\n\r\n";
    const bare = try flow.call(try flow.head(session_template, .{cookie_pair}), "");
    const repaired = bare.header("Set-Cookie").?;
    try std.testing.expect(std.mem.startsWith(u8, repaired, "publr_signed_in=1; Path=/;"));

    const both = try std.fmt.allocPrint(std.testing.allocator, "{s}; publr_signed_in=1", .{
        cookie_pair,
    });
    defer std.testing.allocator.free(both);
    const whole = try flow.call(try flow.head(session_template, .{both}), "");
    try std.testing.expect(whole.header("Set-Cookie") == null);
}

test "oversized health echo returns HTTP 422 and subsequent requests still work" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var flow: routes.testing.Flow = undefined;
    flow.init(
        .{
            .connection = &harness.fixture.connection,
            .auth = &harness.auth,
            .io = std.testing.io,
        },
        arena_state.allocator(),
    );
    const oversized = "GET /api/heartbeat/check?echo=" ++ "x" ** 257 ++
        " HTTP/1.1\r\nHost: h\r\n\r\n";
    const refused = try flow.call(oversized, "");
    try std.testing.expectEqual(@as(u16, 422), refused.status.code());
    const healthy = try flow.call("GET /api/heartbeat/check HTTP/1.1\r\nHost: h\r\n\r\n", "");
    try std.testing.expectEqual(@as(u16, 200), healthy.status.code());
}
