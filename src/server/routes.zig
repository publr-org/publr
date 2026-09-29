const std = @import("std");
const auth = @import("../lib/auth.zig");
const rest = @import("../adapters/rest.zig");
const sdk = @import("../sdk.zig");
const registry = @import("registry.zig");
const heartbeat = @import("../operations/heartbeat.zig");
const http = @import("../lib/http.zig");
const admin = @import("../adapters/admin.zig");
const identity_module = @import("../adapters/rest/identity.zig");
const rest_auth = @import("../adapters/rest/auth.zig");
const rest_providers = @import("../adapters/rest/providers.zig");
const apps_adapter = @import("../adapters/apps.zig");

const Error = http.Error;
const Request = http.Request;
const Response = http.Response;
const Context = http.Context;

pub const Project = @import("project.zig").Project;
/// `/auth/<provider>` and its callback, for every provider a plugin declares.
pub const provider_routes = rest_providers.Routes(registry.sign_in_providers);

pub fn register(router: *http.Router) void {
    std.debug.assert(router.routes_len == 0);

    // First, so it runs last: whatever the rest leaves without a cache policy is private.
    router.use(&private_by_default);
    // Behind a CDN that purges: every write answers with the dependency keys it raised.
    router.use(&apps_adapter.edge.changes);
    router.get("/api/health", &health);
    router.post("/api/auth/sign-in", &rest_auth.sign_in);
    router.post("/api/auth/sign-out", &rest_auth.sign_out);
    router.post("/api/auth/set-password", &rest_auth.set_password);
    router.get("/api/auth/session", &rest_auth.whoami);
    router.get("/auth/sign-on", &rest_auth.sign_on);
    router.post("/auth/sign-on", &rest_auth.sign_on);
    provider_routes.register(router);
    admin.register(router);
    rest.register(router);
    apps_adapter.register(router);

    const fixed = 9 + provider_routes.routes_count;

    std.debug.assert(router.routes_len == fixed + admin.routes_count + apps_adapter.routes_count);
}

/// Router middleware: a response that did not choose a cache policy gets `private, no-store`,
/// so no shared cache (a CDN, a proxy) ever keeps it. Only what says it is public (built
/// pages, static islands, app assets) is cacheable; a response that forgets is per-user
/// by default, not everyone's, whatever the cache in front is configured to do.
pub fn private_by_default(
    request: *Request,
    response: *Response,
    ctx: *Context,
    next: http.Router.Next,
) anyerror!void {
    try next.run(request, response, ctx);

    if (response.header("Cache-Control") == null) {
        try response.set_header("Cache-Control", "private, no-store");
    }

    std.debug.assert(response.header("Cache-Control") != null);
}

pub fn register_static(router: *http.Router) void {
    std.debug.assert(router.routes_len == 0);

    router.get("/", &static_file);
    router.get("/*", &static_file);

    std.debug.assert(router.routes_len == 2);
}

fn static_file(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(ctx.user_data != null);

    const project = Project.of(ctx);
    const dir = project.static_dir orelse return response.text(.not_found, "Not Found");

    std.debug.assert(dir.len > 0);

    const cap = ctx.options.response_bytes_max;

    switch (try http.static.serve_file(dir, request.path(), response, ctx.arena, cap)) {
        .served => try response.set_header("Cache-Control", "no-cache"),
        .not_found => try response.text(.not_found, "Not Found"),
        .too_large => try response.text(.internal_server_error, "file too large for this server"),
    }
}

fn health(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(ctx.user_data != null);
    std.debug.assert(request.method() == .get or request.method() == .head);

    const project = Project.of(ctx);
    const identity = identity_module.identify(request, ctx.arena, project);
    var sdk_ctx = identity_module.context(project, ctx.arena, identity.caller);

    const out = registry.SDK.dispatch(&sdk_ctx, heartbeat.Check, .{}) catch |err| {
        try response.text(.internal_server_error, @errorName(err));
        return;
    };

    try response.json(.ok, out);
}

/// For tests: an offline app with every route, driven with raw request text.
pub const testing = struct {
    pub const Flow = struct {
        app: http.App,
        project: Project,
        arena: std.mem.Allocator,

        /// In place: the app keeps a pointer to `site`.
        pub fn init(flow: *Flow, project: Project, arena: std.mem.Allocator) void {
            std.debug.assert(project.connection.transaction_depth == 0);

            flow.* = .{ .app = http.App.offline(.{}), .project = project, .arena = arena };
            flow.app.user_data = &flow.project;
            register(flow.app.router());

            std.debug.assert(flow.app.routes.routes_len > 0);
        }

        pub fn head(flow: *Flow, comptime template: []const u8, args: anytype) ![]const u8 {
            std.debug.assert(template.len > 0);
            std.debug.assert(std.mem.endsWith(u8, template, "\r\n\r\n"));

            return std.fmt.allocPrint(flow.arena, template, args);
        }

        pub fn call(flow: *Flow, head_text: []const u8, body: []const u8) !http.Response {
            std.debug.assert(head_text.len > 0);
            std.debug.assert(std.mem.endsWith(u8, head_text, "\r\n\r\n"));

            const parsed = try http.parse(head_text);
            const wire = parsed.complete;
            var request: http.Request = .{ .inner = &wire, .body = body };

            return flow.app.handle(flow.arena, &request);
        }
    };
};

test "with no apps, / opens the admin and every other page is not found" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var flow: testing.Flow = undefined;
    flow.init(.{
        .connection = &harness.fixture.connection,
        .auth = &harness.auth,
        .io = std.testing.io,
    }, arena_state.allocator());

    const root = try flow.call("GET / HTTP/1.1\r\nHost: h\r\n\r\n", "");
    try std.testing.expectEqual(@as(u16, 303), root.status.code());
    try std.testing.expectEqualStrings("/admin", root.header("Location").?);

    const other = try flow.call("GET /about HTTP/1.1\r\nHost: h\r\n\r\n", "");
    try std.testing.expectEqual(@as(u16, 404), other.status.code());

    flow.project.apps_failed = true;

    const failed = try flow.call("GET / HTTP/1.1\r\nHost: h\r\n\r\n", "");
    try std.testing.expectEqual(@as(u16, 503), failed.status.code());
}

test "the admin's door: an account whose roles reach none of its operations stays out" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var flow: admin.Flow = .{ .inner = undefined };
    flow.inner.init(.{
        .connection = &harness.fixture.connection,
        .auth = &harness.auth,
        .io = std.testing.io,
    }, arena_state.allocator());

    const setup_body = "email=ada%40example.com&display_name=Ada&password=correct+horse+battery";
    _ = try flow.call("POST", "/admin/setup", setup_body);
    _ = try flow.call("POST", "/admin/logout", try std.fmt.allocPrint(
        arena_state.allocator(),
        "csrf={s}",
        .{flow.csrf_of((try flow.call("GET", "/admin/content", "")).body)},
    ));

    // A role no native code declares grants nothing: the account is an app's visitor.
    var system = harness.ctx(.system);
    const users = @import("../operations/user.zig");
    const visitor = try registry.SDK.dispatch(&system, users.Create, .{
        .email = "v@x.test",
        .display_name = "V",
        .password = "correct horse battery",
    });
    const connection = system.db;
    const stored = try @import("../store.zig").users.update(connection, visitor.user_id, "V", &.{
        "ghost",
    }, 0);

    try std.testing.expect(stored);
    flow.cookie = "";

    const refused = try flow.call(
        "POST",
        "/admin/login",
        "email=v%40x.test&password=correct+horse+battery",
    );
    try std.testing.expect(std.mem.indexOf(u8, refused.body, admin.auth_pages.no_access) != null);
    try std.testing.expectEqualStrings("", flow.cookie);

    // Signed in elsewhere (an app's own sign-in), every admin URL sends it back.
    const api = try flow.inner.call(
        "POST /api/auth/sign-in HTTP/1.1\r\nHost: h\r\nOrigin: http://h\r\n" ++
            "Content-Type: application/json\r\nContent-Length: 0\r\n\r\n",
        "{\"email\":\"v@x.test\",\"password\":\"correct horse battery\"}",
    );
    const cookie = api.header("Set-Cookie").?;
    flow.cookie = cookie[0..std.mem.indexOfScalar(u8, cookie, ';').?];

    for ([_][]const u8{ "/admin", "/admin/content", "/admin/settings/users" }) |path| {
        const turned = try flow.call("GET", path, "");
        try std.testing.expectEqualStrings("/admin/login", turned.header("Location").?);
    }

    const login = try flow.call("GET", "/admin/login", "");
    try std.testing.expect(std.mem.indexOf(u8, login.body, admin.auth_pages.no_access) != null);
}

test "the rail shows an editor Content, and an administrator Structure and Settings too" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var flow: admin.Flow = .{ .inner = undefined };
    flow.inner.init(.{
        .connection = &harness.fixture.connection,
        .auth = &harness.auth,
        .io = std.testing.io,
    }, arena);

    const setup_body = "email=ada%40example.com&display_name=Ada&password=correct+horse+battery";
    _ = try flow.call("POST", "/admin/setup", setup_body);

    const structure = "href=\"/admin/structure\"";
    const settings = "href=\"/admin/settings\"";
    const administrator = try flow.call("GET", "/admin/content", "");
    try std.testing.expect(std.mem.indexOf(u8, administrator.body, structure) != null);
    try std.testing.expect(std.mem.indexOf(u8, administrator.body, settings) != null);

    var system = harness.ctx(.system);
    const users = @import("../operations/user.zig");
    _ = try registry.SDK.dispatch(&system, users.Create, .{
        .email = "ed@x.test",
        .display_name = "Ed",
        .password = "correct horse battery",
    });
    flow.cookie = "";
    _ = try flow.call("POST", "/admin/login", "email=ed%40x.test&password=correct+horse+battery");

    const editor = try flow.call("GET", "/admin/content", "");
    try std.testing.expectEqual(@as(u16, 200), editor.status.code());
    try std.testing.expect(std.mem.indexOf(u8, editor.body, structure) == null);
    try std.testing.expect(std.mem.indexOf(u8, editor.body, settings) == null);
}
