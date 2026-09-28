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
const site_adapter = @import("../adapters/site.zig");

const Error = http.Error;
const Request = http.Request;
const Response = http.Response;
const Context = http.Context;

pub const Site = @import("site.zig").Site;

pub fn register(router: *http.Router) void {
    std.debug.assert(router.routes_len == 0);

    // First, so it runs last: whatever the rest leaves without a cache policy is private.
    router.use(&private_by_default);
    // Behind a CDN that purges: every write answers with the dependency keys it raised.
    router.use(&site_adapter.edge.changes);
    router.get("/api/health", &health);
    router.post("/api/auth/sign-in", &rest_auth.sign_in);
    router.post("/api/auth/sign-out", &rest_auth.sign_out);
    router.post("/api/auth/set-password", &rest_auth.set_password);
    router.get("/api/auth/session", &rest_auth.whoami);
    router.get("/auth/sign-on", &rest_auth.sign_on);
    router.post("/auth/sign-on", &rest_auth.sign_on);
    admin.register(router);
    rest.register(router);
    site_adapter.register(router);

    std.debug.assert(router.routes_len == 9 + admin.routes_count + site_adapter.routes_count);
}

/// Router middleware: a response that did not choose a cache policy gets `private, no-store`,
/// so no shared cache (a CDN, a proxy) ever keeps it. Only what says it is public (built
/// pages, static islands, theme assets) is cacheable; a response that forgets is per-user
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

    const site = Site.of(ctx);
    const dir = site.static_dir orelse return response.text(.not_found, "Not Found");

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

    const site = Site.of(ctx);
    const identity = identity_module.identify(request, ctx.arena, site);
    var sdk_ctx = identity_module.context(site, ctx.arena, identity.caller);

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
        site: Site,
        arena: std.mem.Allocator,

        /// In place: the app keeps a pointer to `site`.
        pub fn init(flow: *Flow, site: Site, arena: std.mem.Allocator) void {
            std.debug.assert(site.connection.transaction_depth == 0);

            flow.* = .{ .app = http.App.offline(.{}), .site = site, .arena = arena };
            flow.app.user_data = &flow.site;
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

test "with no public site, / opens the admin and every other page is not found" {
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

    flow.site.public_failed = true;

    const failed = try flow.call("GET / HTTP/1.1\r\nHost: h\r\n\r\n", "");
    try std.testing.expectEqual(@as(u16, 503), failed.status.code());
}
