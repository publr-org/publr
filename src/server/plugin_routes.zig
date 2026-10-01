//! The HTTP routes compiled-in plugins declare, registered ahead of the core's so their own
//! paths reach them, and checked at startup: a plugin's prefix must not cover a core route.
const std = @import("std");
const http = @import("../lib/http.zig");
const route = @import("../sdk/plugin/route.zig");
const sdk = @import("../sdk.zig");
const identity = @import("../adapters/rest/identity.zig");
const Project = @import("project.zig").Project;

/// A core route a plugin's prefix covers.
pub const Conflict = struct { owner: []const u8, prefix: []const u8, pattern: []const u8 };

pub fn Routes(comptime declared: []const route.Declared) type {
    return struct {
        pub const routes_count: u32 = declared.len;

        /// Before any core route, so a plugin's path is never answered by a core pattern.
        pub fn register(router: *http.Router) void {
            const before = router.routes_len;

            std.debug.assert(before + routes_count <= router.routes.len);

            inline for (declared) |one| {
                switch (one.route.method) {
                    .get => router.get(one.route.path, one.route.handler),
                    .post => router.post(one.route.path, one.route.handler),
                }
            }

            std.debug.assert(router.routes_len == before + routes_count);
        }

        /// The first core route, registered after the plugins' from `first_core` on, that a
        /// plugin's prefix covers; null when none does.
        pub fn shadowed(router: *const http.Router, first_core: u32) ?Conflict {
            std.debug.assert(first_core <= router.routes_len);

            for (router.routes[first_core..router.routes_len]) |core| {
                inline for (declared) |one| {
                    if (route.under(core.pattern, one.prefix)) {
                        return .{
                            .owner = one.owner,
                            .prefix = one.prefix,
                            .pattern = core.pattern,
                        };
                    }
                }
            }

            return null;
        }
    };
}

/// Refuses to start when a plugin's prefix covers a core route: a plugin named after a
/// part of the admin would take its pages.
pub fn assert_unshadowed(conflict: ?Conflict) void {
    const found = conflict orelse return;

    std.debug.assert(found.owner.len > 0);
    std.debug.panic("plugin {s}: its routes under {s} would take the core's {s}", .{
        found.owner,
        found.prefix,
        found.pattern,
    });
}

/// The SDK context of whoever sent the request, for a plugin's handler to call operations
/// as them, the way the REST API does: a write must come from this site with the session's
/// CSRF token. Null when it does not; the refusal is already written.
pub fn caller_context(
    request: *const http.Request,
    response: *http.Response,
    ctx: *http.Context,
) http.Error!?sdk.Ctx {
    std.debug.assert(ctx.user_data != null);

    const project = Project.of(ctx);
    const found = identity.identify(request, ctx.arena, project);
    const is_read = request.method() == .get or request.method() == .head;

    if (!is_read and !try identity.guard(request, response, project, &found)) {
        return null;
    }

    return identity.context(project, ctx.arena, found.caller);
}

/// The session a plugin's handler signed someone in to, as this site's session cookie: what
/// a sign-in of a plugin's own sets, the way the core's sign-in does.
pub fn set_session(
    request: *const http.Request,
    response: *http.Response,
    ctx: *http.Context,
    token: []const u8,
    expires_at_ms: i64,
) http.Error!void {
    std.debug.assert(ctx.user_data != null);
    std.debug.assert(token.len > 0);

    const project = Project.of(ctx);
    const now_ms = sdk.context.wall_clock_ms(project.io);

    try identity.set_session_cookie(
        project,
        request,
        response,
        ctx.arena,
        token,
        expires_at_ms,
        now_ms,
    );
}

const Testing = @import("../sdk/plugin.zig").testing;
const TestRoutes = Routes(@import("../sdk/plugin.zig").Merged(.{Testing.Hello}).merged_routes);

const Served = struct {
    app: http.App,
    project: Project,

    fn init(served: *Served, harness: *sdk.testing.Harness) void {
        std.debug.assert(harness.fixture.connection.transaction_depth == 0);

        served.* = .{
            .app = http.App.offline(.{}),
            .project = .{
                .connection = &harness.fixture.connection,
                .auth = &harness.auth,
                .io = std.testing.io,
            },
        };
        served.app.user_data = &served.project;
        TestRoutes.register(served.app.router());
    }

    fn send(served: *Served, arena: std.mem.Allocator, head: []const u8) !http.Response {
        std.debug.assert(head.len > 0);

        const parsed = try http.parse(head);
        const wire = parsed.complete;
        var request: http.Request = .{ .inner = &wire, .body = "" };

        return served.app.handle(arena, &request);
    }
};

test "a plugin's route answers, as whoever sent the request" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var served: Served = undefined;
    served.init(&harness);

    const head = "GET /api/hello/greeting HTTP/1.1\r\nHost: h\r\n\r\n";
    const answered = try served.send(arena, head);

    try std.testing.expectEqual(@as(u16, 200), answered.status.code());
    try std.testing.expectEqualStrings("{\"caller\":\"anonymous\"}", answered.body);

    const foreign = "POST /api/hello/greeting HTTP/1.1\r\nHost: h\r\n" ++
        "Origin: https://elsewhere.test\r\nContent-Length: 0\r\n\r\n";
    const refused = try served.send(arena, foreign);

    try std.testing.expectEqual(@as(u16, 403), refused.status.code());
}

test "a core route under a plugin's prefix is refused; one beside it is not" {
    var app = http.App.offline(.{});
    const router = app.router();

    TestRoutes.register(router);

    const first_core = router.routes_len;

    router.get("/api/helloworld", &nothing);
    try std.testing.expect(TestRoutes.shadowed(router, first_core) == null);

    router.get("/api/hello/:id", &nothing);
    const conflict = TestRoutes.shadowed(router, first_core).?;

    try std.testing.expectEqualStrings("hello", conflict.owner);
    try std.testing.expectEqualStrings("/api/hello/:id", conflict.pattern);
}

fn nothing(_: *http.Request, response: *http.Response, _: *http.Context) http.Error!void {
    std.debug.assert(response.status.code() > 0);
}
