//! The apps: every request no other route took, sent to the app mounted where it asked
//! (its subdomain, else the longest path), then to that app's assets, islands or pages;
//! and the caching policy every app's response carries.

const std = @import("std");
const http = @import("../lib/http.zig");
const state = @import("apps/state.zig");
const pages = @import("apps/pages.zig");
const api = @import("apps/api.zig");
const islands = @import("apps/islands.zig");
const assets = @import("apps/assets.zig");
const toolbar = @import("apps/toolbar.zig");
const Project = @import("../server/project.zig").Project;

pub const spec = @import("apps/spec.zig");
pub const query = @import("apps/query.zig");
pub const context = @import("apps/context.zig");
pub const build = @import("apps/build.zig");
pub const rebuild = @import("apps/rebuild.zig");
pub const middleware = @import("apps/middleware.zig");
pub const edge = @import("apps/edge.zig");
pub const artifacts = @import("apps/artifacts.zig");
pub const load = @import("apps/load.zig");
pub const folder = @import("apps/folder.zig");
pub const App = state.App;
pub const Options = state.Options;
pub const valid_options = state.valid_options;
pub const check_apps = state.check_apps;
pub const check_specs = state.check_specs;
pub const routes_count: u32 = 1;

const Request = http.Request;
const Response = http.Response;
const Error = http.Error;

pub fn register(router: *http.Router) void {
    std.debug.assert(router.routes_len < 256 - routes_count);

    const before = router.routes_len;

    router.get(toolbar.toolbar_path, &toolbar.toolbar);
    router.not_found = &dispatch;

    std.debug.assert(router.routes_len == before + routes_count);
}

/// Every request no other route took: the app mounted where it asked. With no app there,
/// `/` opens the admin and anything else is not found.
fn dispatch(request: *Request, response: *Response, ctx: *http.Context) anyerror!void {
    std.debug.assert(ctx.user_data != null);
    std.debug.assert(request.path().len > 0);

    const project = Project.of(ctx);

    if (project.apps_failed) {
        return pages.unavailable(response);
    }

    const host = request.header("host") orelse "";
    const target = project.resolve(host, request.path()) orelse {
        if (std.mem.eql(u8, request.path(), "/")) {
            return response.redirect(.see_other, "/admin");
        }

        return response.text(.not_found, "Not Found");
    };

    if (std.mem.startsWith(u8, target.path, assets.prefix)) {
        return assets.serve(target.app, target.path, request, response, ctx);
    }

    if (std.mem.startsWith(u8, target.path, islands.islands_prefix)) {
        return islands.island(project, target, request, response, ctx);
    }

    if (std.mem.startsWith(u8, target.path, api.prefix)) {
        return api.call(project, target, request, response, ctx);
    }

    return pages.dispatch(project, target, request, response, ctx);
}

/// Where the bytes of a response came from, written as `X-Publr-Served` and deciding the
/// cache policy: a file the build wrote is `public, no-cache` (every use revalidates,
/// cheaply, by ETag); an asset from memory is kept an hour, or a year when fingerprinted;
/// a render is `no-store`. An island's `cache` relaxes the first and last into a max-age.
pub const Served = enum { file, memory, render };

pub const Cache = struct {
    max_age: u32 = 0,
    /// `stale-while-revalidate`: serve the stale copy while the revalidation runs.
    stale: u32 = 0,
};

pub fn serve_as(response: *Response, app: *const App, served: Served) Error!void {
    std.debug.assert(app.css.len > 0);
    std.debug.assert(response.body.len == 0);

    try serve(response, app, served, .{});
}

pub fn serve(response: *Response, app: *const App, served: Served, cache: Cache) Error!void {
    std.debug.assert(app.css.len > 0);
    std.debug.assert(cache.stale == 0 or served == .file);

    try response.set_header("X-Publr-Served", @tagName(served));

    if (app.options.dev) {
        return response.set_header("Cache-Control", "no-store");
    }

    const value = switch (served) {
        .file => if (cache.stale > 0)
            try std.fmt.allocPrint(response.arena, "public, max-age={d}, " ++
                "stale-while-revalidate={d}", .{ cache.max_age, cache.stale })
        else if (cache.max_age == 0)
            "public, no-cache"
        else
            try std.fmt.allocPrint(response.arena, "public, max-age={d}", .{cache.max_age}),
        .memory => if (cache.max_age == 0)
            "public, max-age=3600"
        else
            try std.fmt.allocPrint(response.arena, "public, max-age={d}, immutable", .{
                cache.max_age,
            }),
        .render => if (cache.max_age == 0)
            "no-store"
        else
            try std.fmt.allocPrint(response.arena, "private, max-age={d}", .{cache.max_age}),
    };

    try response.set_header("Cache-Control", value);

    // A CDN that purges on change keeps built files far longer than browsers do.
    if (served == .file and app.options.edge_max_age > 0) {
        const lifetime = try std.fmt.allocPrint(response.arena, "max-age={d}", .{
            app.options.edge_max_age,
        });

        try response.set_header("CDN-Cache-Control", lifetime);
    }
}

/// A built file with its `ETag`: a consumer that already holds these exact bytes gets
/// `304 Not Modified` and no body, which is what makes `no-cache` cheap.
pub fn serve_file(
    request: *const Request,
    response: *Response,
    app: *const App,
    status: http.Status,
    html: []const u8,
    cache: Cache,
) Error!void {
    std.debug.assert(html.len > 0);
    std.debug.assert(response.body.len == 0);

    const hash = std.hash.Fnv1a_64.hash(html);
    const tag = try std.fmt.allocPrint(response.arena, "\"{x:0>16}\"", .{hash});

    try serve(response, app, .file, cache);
    try response.set_header("ETag", tag);

    if (request.header("if-none-match")) |held| {
        if (std.mem.indexOf(u8, held, tag) != null) {
            response.status = .not_modified;
            response.body = "";

            return;
        }
    }

    try response.set_body(status, "text/html; charset=utf-8", html);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(state);
    std.testing.refAllDecls(pages);
    std.testing.refAllDecls(islands);
    std.testing.refAllDecls(assets);
    std.testing.refAllDecls(rebuild);
    std.testing.refAllDecls(middleware);
    std.testing.refAllDecls(edge);
    std.testing.refAllDecls(@import("apps/public.zig"));
    std.testing.refAllDecls(@import("apps/imported.zig"));
}

const sdk = @import("../sdk.zig");
const registry = @import("../server/registry.zig");
const routes = @import("../server/routes.zig");
const deps = @import("../lib/deps.zig");
const record_operations = @import("../operations/record.zig");
const content_type_operations = @import("../operations/content_type.zig");
const content_type = @import("../model/content_type.zig");

/// A database holding the fixture apps' public `post` type, every fixture app loaded over
/// it, and an offline server with every route mounted. `app` is the one at the root. Other
/// adapters' tests that need the fixture apps use it too.
pub const Harness = struct {
    inner: sdk.testing.Harness,
    index: deps.Index,
    apps: [spec.all.len]App,
    app: *App,
    flow: routes.testing.Flow,
    arena_state: std.heap.ArenaAllocator,
    /// Where the apps build unless a test names a folder: never the repository's `output/`.
    scratch: std.testing.TmpDir,

    pub fn init(harness: *Harness, given: Options) !void {
        std.debug.assert(given.output_dir.len > 0);
        std.debug.assert(given.base_url.len > 0);

        try harness.inner.init();
        errdefer harness.inner.deinit();

        harness.arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer harness.arena_state.deinit();

        harness.scratch = std.testing.tmpDir(.{});
        errdefer harness.scratch.cleanup();

        const connection = &harness.inner.fixture.connection;
        const now_ms = sdk.context.wall_clock_ms(std.testing.io);
        const arena = harness.arena_state.allocator();
        var options = given;

        options.apps_dir = "fixtures/apps";

        if (std.mem.eql(u8, options.output_dir, state.output_dir_default)) {
            const scratch = harness.scratch.dir;

            options.output_dir = try scratch.realPathFileAlloc(std.testing.io, ".", arena);
        }

        harness.index = try deps.Index.open(connection, .{ .quiet_ms = deps.quiet_ms });
        try harness.load(options, now_ms);
        errdefer harness.unload();

        harness.flow.init(.{
            .connection = connection,
            .auth = &harness.inner.auth,
            .io = std.testing.io,
            .apps = &harness.apps,
            .domain = @import("../model/app.zig").domain_of(options.base_url),
        }, harness.arena_state.allocator());

        const post = try content_type.encode(arena, content_type.test_post);
        var system = harness.inner.ctx(.system);

        system.now_ms = now_ms;
        try registry.SDK.bootstrap(&system);
        _ = try registry.SDK.dispatch(&system, content_type_operations.Create, .{
            .definition = post,
        });
    }

    fn load(harness: *Harness, options: Options, now_ms: i64) !void {
        std.debug.assert(spec.all.len > 0);
        std.debug.assert(now_ms >= 0);

        var loaded: u32 = 0;
        errdefer for (harness.apps[0..loaded]) |*app| app.deinit();

        for (spec.all, &harness.apps) |*app_spec, *app| {
            const gpa = std.testing.allocator;

            try app.init(app_spec, gpa, std.testing.io, &harness.index, options, now_ms);
            loaded += 1;
        }

        harness.app = &harness.apps[0];

        for (&harness.apps) |*app| {
            if (std.mem.eql(u8, app.spec.name, "www")) {
                harness.app = app;
            }
        }
    }

    fn unload(harness: *Harness) void {
        std.debug.assert(harness.apps.len == spec.all.len);
        std.debug.assert(harness.app.css.len > 0);

        for (&harness.apps) |*app| {
            app.deinit();
        }
    }

    pub fn deinit(harness: *Harness) void {
        std.debug.assert(harness.flow.project.apps.len == spec.all.len);

        harness.unload();
        harness.scratch.cleanup();
        harness.arena_state.deinit();
        harness.inner.deinit();
    }

    fn get(harness: *Harness, path: []const u8) !http.Response {
        const head = try harness.flow.head("GET {s} HTTP/1.1\r\nHost: h\r\n\r\n", .{path});

        return harness.flow.call(head, "");
    }

    /// A live post; its slug comes from the title.
    fn publish(harness: *Harness, title: []const u8) ![]const u8 {
        std.debug.assert(title.len > 0);
        std.debug.assert(title.len < 200);

        var system = harness.inner.ctx(.system);
        system.now_ms = sdk.context.wall_clock_ms(std.testing.io);

        const document = try std.fmt.allocPrint(
            harness.arena_state.allocator(),
            "{{\"title\":\"{s}\"}}",
            .{title},
        );
        const created = try registry.SDK.dispatch(&system, record_operations.Create, .{
            .type = "post",
            .document = document,
            .status = "published",
        });

        return created.slug.?;
    }
};

fn contains(text: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, text, needle) != null;
}

test "unbuilt: the app's routes render now, and the app's 404 page answers the rest" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();

    const slug = try harness.publish("Hello <site>");
    try std.testing.expectEqualStrings("hello-site", slug);

    const home = try harness.get("/");
    try std.testing.expectEqual(@as(u16, 200), home.status.code());
    try std.testing.expectEqualStrings("render", home.header("X-Publr-Served").?);
    try std.testing.expectEqualStrings("no-store", home.header("Cache-Control").?);
    try std.testing.expect(contains(home.body, "<title>Publr</title>"));
    try std.testing.expect(contains(home.body, "<style>"));
    // Fetched only for someone signed in; everyone else keeps the build's own copy.
    const placeholder = "<publr-island src=\"/_islands/signed-in\" credentials " ++
        "if=\"signedIn\" prerendered>";
    try std.testing.expect(contains(home.body, placeholder));
    try std.testing.expect(contains(home.body, "islands.condition('signedIn'"));
    try std.testing.expect(contains(home.body, "Hello &lt;site&gt;"));

    const page = try harness.get("/posts/hello-site");
    try std.testing.expectEqual(@as(u16, 200), page.status.code());
    try std.testing.expect(contains(page.body, "sm:text-5xl\">Hello &lt;site&gt;</h1>"));
    try std.testing.expect(contains(page.body, "<code>hello-site</code>"));

    const missing = try harness.get("/posts/nope");
    try std.testing.expectEqual(@as(u16, 404), missing.status.code());
    try std.testing.expect(contains(missing.body, "Nothing lives at this address."));

    const favicon = try harness.get("/favicon.ico");
    try std.testing.expectEqual(@as(u16, 404), favicon.status.code());
    try std.testing.expect(!contains(favicon.body, "<html"));

    const live = try harness.get("/visit");
    try std.testing.expectEqual(@as(u16, 200), live.status.code());
    try std.testing.expect(contains(live.body, "hover:text-accent\">Sign in</a>"));
    try std.testing.expect(!contains(live.body, "/_islands/signed-in"));
}

const middleware_testing = struct {
    fn run(request: *middleware.Request) anyerror!?middleware.Response {
        std.debug.assert(request.path().len > 0);

        if (std.mem.eql(u8, request.path(), "/go")) {
            const to = request.query("to") orelse "/";

            return request.redirect(request.print("https://elsewhere.test{s}", .{to}));
        }

        if (request.starts_with("/members") and request.user() == null) {
            return request.redirect("/login");
        }

        if (std.mem.eql(u8, request.path(), "/count")) {
            const listed = try request.call(record_operations.List, .{ .type = "post" });

            return request.json(.{
                .method = request.method(),
                .posts = listed.records.len,
                .nickname = try request.user_field("profile.nickname"),
            });
        }

        return null;
    }
};

test "middleware answers before the site, or lets the request through" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();

    harness.app.middleware = &middleware_testing.run;
    _ = try harness.publish("Hello");

    const away = try harness.get("/go?to=/docs");
    try std.testing.expectEqual(@as(u16, 303), away.status.code());
    try std.testing.expectEqualStrings("https://elsewhere.test/docs", away.header("Location").?);
    try std.testing.expectEqualStrings("private, no-store", away.header("Cache-Control").?);

    const guarded = try harness.get("/members/area");
    try std.testing.expectEqualStrings("/login", guarded.header("Location").?);

    // It runs operations as the visitor, and sees every method, not only GET.
    const head = try harness.flow.head("POST /count HTTP/1.1\r\nHost: h\r\n\r\n", .{});
    const counted = try harness.flow.call(head, "");
    const expected = "{\"method\":\"POST\",\"posts\":1,\"nickname\":null}";

    try std.testing.expectEqualStrings(expected, counted.body);

    // Silence: the site as usual.
    const home = try harness.get("/");
    try std.testing.expectEqual(@as(u16, 200), home.status.code());
    try std.testing.expectEqualStrings("render", home.header("X-Publr-Served").?);
}

test "a type the site does not have is an empty collection, and its entry a 404" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();

    const arena = harness.arena_state.allocator();
    const ctx: context.Context = .{
        .arena = arena,
        .project = &harness.flow.project,
        .app = harness.app,
    };
    const none = try ctx.query("nope", .{});
    try std.testing.expectEqual(@as(usize, 0), none.len);
    try std.testing.expectError(error.EntryNotFound, ctx.entry("nope", "x"));

    const home = try harness.get("/");
    try std.testing.expectEqual(@as(u16, 200), home.status.code());
}

test "a per-request render reads as the visitor, live records only; a shared one as nobody" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();

    const arena = harness.arena_state.allocator();
    var system = harness.inner.ctx(.system);
    var private = @import("../model.zig").content_type.test_post;
    private.handle = "note";
    private.name = "Note";
    private.public = false;
    const definition = try @import("../model.zig").content_type.encode(arena, private);
    const types = @import("../operations/content_type.zig");
    _ = try registry.SDK.dispatch(&system, types.Create, .{ .definition = definition });
    _ = try registry.SDK.dispatch(&system, record_operations.Create, .{
        .type = "note",
        .document = "{\"title\":\"Mine, live\",\"body\":\"x\"}",
        .status = "published",
    });
    _ = try registry.SDK.dispatch(&system, record_operations.Create, .{
        .type = "note",
        .document = "{\"title\":\"Mine, draft\",\"body\":\"y\"}",
    });

    const shared: context.Context = .{
        .arena = arena,
        .project = &harness.flow.project,
        .app = harness.app,
    };
    try std.testing.expectEqual(@as(usize, 0), (try shared.query("note", .{})).len);

    var visitor = shared;
    visitor.live = true;
    visitor.caller = .{ .user = .{ .id = "u_1", .roles = &.{"editor"} } };
    const seen = try visitor.query("note", .{});
    try std.testing.expectEqual(@as(usize, 1), seen.len);
    try std.testing.expectEqualStrings("Mine, live", seen[0].title);

    var nobody = shared;
    nobody.live = true;
    try std.testing.expectEqual(@as(usize, 0), (try nobody.query("note", .{})).len);
}

test "islands: a dynamic fragment is rendered per request and never kept, a static one is shared" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();

    _ = try harness.publish("One");

    const signed_in = try harness.get("/_islands/signed-in");
    try std.testing.expectEqual(@as(u16, 200), signed_in.status.code());
    try std.testing.expect(contains(signed_in.body, "<template patchfor=\"signed-in\">"));
    try std.testing.expectEqualStrings("no-store", signed_in.header("Cache-Control").?);
    try std.testing.expectEqualStrings("Cookie", signed_in.header("Vary").?);

    var key: []const u8 = "";

    for (harness.app.pages().islands) |island| {
        if (!island.dynamic and std.mem.startsWith(u8, island.key, "latest-posts")) {
            key = island.key;
        }
    }

    try std.testing.expect(key.len > 0);

    const path = try std.fmt.allocPrint(harness.arena_state.allocator(), "/_islands/{s}", .{key});
    const latest = try harness.get(path);
    try std.testing.expectEqual(@as(u16, 200), latest.status.code());
    try std.testing.expectEqualStrings("*", latest.header("Access-Control-Allow-Origin").?);
    try std.testing.expect(contains(latest.body, ">One</a>"));

    const batch = try harness.get("/_islands/?keys=signed-in,clock");
    try std.testing.expectEqual(@as(u16, 200), batch.status.code());
    try std.testing.expect(contains(batch.body, "<template patchfor=\"signed-in\">"));
    try std.testing.expect(contains(batch.body, "<template patchfor=\"clock\">"));

    const unknown = try harness.get("/_islands/nope");
    try std.testing.expectEqual(@as(u16, 404), unknown.status.code());

    // The batch's path never keeps a 404, with or without a query.
    for ([_][]const u8{ "/_islands/", "/_islands/?keys=," }) |bare_path| {
        const bare = try harness.get(bare_path);
        try std.testing.expectEqual(@as(u16, 404), bare.status.code());
        try std.testing.expectEqualStrings("no-store", bare.header("Cache-Control").?);
    }
}

/// A plugin's gate, as a test declares one: the site for members, a page for the rest.
fn members_only(delivery: *const sdk.delivery.Delivery) sdk.Error!sdk.delivery.Verdict {
    std.debug.assert(delivery.path.len > 0);

    if (delivery.visitor.user_id() != null) {
        return .private;
    }

    return .{ .refuse = .{ .status = 403, .body = "<p>Members only</p>" } };
}

test "delivery gates: members see the site, privately; everyone else the gate's answer" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();

    var system = harness.inner.ctx(.system);
    system.now_ms = sdk.context.wall_clock_ms(std.testing.io);
    try @import("../operations/user.zig").seed_admin(&system);
    _ = try harness.publish("Hidden");
    harness.flow.project.delivery_gates = &.{members_only};

    for ([_][]const u8{ "/", "/posts/hidden", "/nope", "/_islands/signed-in" }) |path| {
        const refused = try harness.get(path);
        try std.testing.expectEqual(@as(u16, 403), refused.status.code());
        try std.testing.expect(contains(refused.body, "Members only"));
        try std.testing.expect(!contains(refused.body, "Hidden"));
        try std.testing.expectEqualStrings("private, no-store", refused.header("Cache-Control").?);
    }

    // The app's assets and public files are never gated.
    const style = try harness.get("/_app/app.css");
    try std.testing.expectEqual(@as(u16, 200), style.status.code());
    const logo = try harness.get("/logo.svg");
    try std.testing.expectEqual(@as(u16, 200), logo.status.code());

    const login_head = "POST /api/auth/sign-in HTTP/1.1\r\nHost: h\r\nOrigin: http://h\r\n" ++
        "Content-Length: 0\r\n\r\n";
    const signed = try harness.flow.call(
        login_head,
        "{\"email\":\"admin@example.com\",\"password\":\"correct horse battery\"}",
    );
    const cookie = signed.header("Set-Cookie").?;
    const pair = cookie[0..std.mem.indexOfScalar(u8, cookie, ';').?];
    const template = "GET /posts/hidden HTTP/1.1\r\nHost: h\r\nCookie: {s}\r\n\r\n";
    const member = try harness.flow.call(try harness.flow.head(template, .{pair}), "");
    try std.testing.expectEqual(@as(u16, 200), member.status.code());
    try std.testing.expect(contains(member.body, "Hidden"));
    try std.testing.expectEqualStrings("private, no-store", member.header("Cache-Control").?);

    harness.flow.project.delivery_gates = &.{};
    const open = try harness.get("/posts/hidden");
    try std.testing.expectEqual(@as(u16, 200), open.status.code());
}

test "assets: the stylesheet and the loader from memory, immutable under the fingerprint" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();

    const sheet = try harness.get("/_app/app.css");
    try std.testing.expectEqual(@as(u16, 200), sheet.status.code());
    try std.testing.expect(contains(sheet.body, ".bg-canvas"));
    try std.testing.expectEqualStrings("public, max-age=3600", sheet.header("Cache-Control").?);

    const arena = harness.arena_state.allocator();
    const version: []const u8 = &harness.app.version;
    const stamped = try std.fmt.allocPrint(arena, "/_app/islands.js?v={s}", .{version});
    const loader = try harness.get(stamped);
    try std.testing.expectEqual(@as(u16, 200), loader.status.code());
    try std.testing.expect(contains(loader.body, "customElements.define('publr-island'"));
    const immutable = "public, max-age=31536000, immutable";
    try std.testing.expectEqualStrings(immutable, loader.header("Cache-Control").?);

    const runtime = try harness.get("/_app/publr.js");
    try std.testing.expectEqual(@as(u16, 200), runtime.status.code());
    try std.testing.expect(contains(runtime.body, "?v="));

    const missing = try harness.get("/_app/nope.css");
    try std.testing.expectEqual(@as(u16, 404), missing.status.code());
}

const edge_testing = struct {
    fn private_gate(_: *const sdk.delivery.Delivery) sdk.Error!sdk.delivery.Verdict {
        return .private;
    }
};

test "a CDN keeps built pages and static islands longer, never what a gate made private" {
    var harness: Harness = undefined;
    try harness.init(.{ .edge_max_age = 86_400 });
    defer harness.deinit();

    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();

    harness.app.output = scratch.dir;
    defer harness.app.output = null;

    _ = try harness.publish("Edge");
    _ = try build.build(harness.app, &harness.flow.project);

    const page = try harness.get("/posts/edge");
    try std.testing.expectEqualStrings("file", page.header("X-Publr-Served").?);
    try std.testing.expectEqualStrings("max-age=86400", page.header("CDN-Cache-Control").?);

    // A static island is a built file too.
    const io = std.testing.io;
    var fragments = try scratch.dir.openDir(io, "_islands", .{ .iterate = true });
    defer fragments.close(io);

    var iterator = fragments.iterate();
    const entry = (try iterator.next(io)).?;
    const key = entry.name[0 .. entry.name.len - ".html".len];
    const arena = harness.arena_state.allocator();
    const island = try harness.get(try std.fmt.allocPrint(arena, "/_islands/{s}", .{key}));
    try std.testing.expectEqualStrings("max-age=86400", island.header("CDN-Cache-Control").?);

    // Rendered per request: nothing for a CDN.
    const visit = try harness.get("/visit");
    try std.testing.expect(visit.header("CDN-Cache-Control") == null);

    // Made private by a gate: kept by nobody, the CDN included.
    harness.flow.project.delivery_gates = &.{edge_testing.private_gate};
    const gated = try harness.get("/posts/edge");
    try std.testing.expectEqualStrings("private, no-store", gated.header("Cache-Control").?);
    try std.testing.expectEqualStrings("no-store", gated.header("CDN-Cache-Control").?);
}

test "behind a CDN: built files carry their keys, a write answers with the keys it raised" {
    var harness: Harness = undefined;
    try harness.init(.{ .edge_max_age = 86_400 });
    defer harness.deinit();

    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();

    harness.app.output = scratch.dir;
    defer harness.app.output = null;

    const slug = try harness.publish("Tagged");
    _ = try build.build(harness.app, &harness.flow.project);

    const arena = harness.arena_state.allocator();
    const page = try harness.get(try std.fmt.allocPrint(arena, "/posts/{s}", .{slug}));
    const tags = page.header("Cache-Tag").?;
    try std.testing.expect(contains(tags, "record:"));
    try std.testing.expect(contains(tags, "template:"));

    // The 404 page is never indexed: any change purges it.
    try std.testing.expectEqualStrings("any", (try harness.get("/nowhere")).header("Cache-Tag").?);

    var system = harness.inner.ctx(.system);
    system.now_ms = sdk.context.wall_clock_ms(std.testing.io);
    try @import("../operations/user.zig").seed_admin(&system);

    // A write that changes nothing a page reads: an empty answer, nothing to purge.
    const login = "POST /api/auth/sign-in HTTP/1.1\r\nHost: h\r\nOrigin: http://h\r\n" ++
        "Content-Length: 0\r\n\r\n";
    const signed = try harness.flow.call(
        login,
        "{\"email\":\"admin@example.com\",\"password\":\"correct horse battery\"}",
    );
    try std.testing.expectEqualStrings("", signed.header(edge.changed_header).?);

    // A post created through the API: exactly the keys it raised.
    const cookie = signed.header("Set-Cookie").?;
    const pair = cookie[0..std.mem.indexOfScalar(u8, cookie, ';').?];
    const csrf_at = std.mem.indexOf(u8, signed.body, "\"csrf\":\"").? + 8;
    const csrf = signed.body[csrf_at .. csrf_at + @import("../lib/auth.zig").csrf.token_len];
    const create = try harness.flow.head("POST /api/record/create HTTP/1.1\r\nHost: h\r\n" ++
        "Origin: http://h\r\nCookie: {s}\r\nX-Csrf-Token: {s}\r\nContent-Length: 0\r\n\r\n", .{
        pair,
        csrf,
    });
    const document = "{\"type\":\"post\",\"document\":\"{\\\"title\\\":\\\"More\\\"}\"," ++
        "\"status\":\"published\"}";
    const created = try harness.flow.call(create, document);
    try std.testing.expectEqual(@as(u16, 200), created.status.code());

    const changed = created.header(edge.changed_header).?;
    try std.testing.expect(contains(changed, "record:"));
    try std.testing.expect(contains(changed, "type:post"));

    // A read never answers with it.
    try std.testing.expect(page.header(edge.changed_header) == null);
}

test "build writes the site, serve prefers the files, a publish rewrites what read the change" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();

    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();

    harness.app.output = scratch.dir;
    defer harness.app.output = null;

    _ = try harness.publish("First");

    const project = &harness.flow.project;
    const summary = try build.build(harness.app, project);
    try std.testing.expect(summary.pages >= 6);
    try std.testing.expect(summary.islands >= 2);
    try std.testing.expect(summary.assets >= 4);

    const arena = harness.arena_state.allocator();
    const io = std.testing.io;
    const home = try scratch.dir.readFileAlloc(io, "index.html", arena, .limited(1 << 20));
    try std.testing.expect(contains(home, ">First</a>"));
    try std.testing.expect(build.built_page(harness.app, arena, "/posts/first") != null);
    try std.testing.expect(build.built_page(harness.app, arena, "/visit") == null);
    try std.testing.expect(build.built_404(harness.app, arena) != null);

    const served = try harness.get("/posts/first");
    try std.testing.expectEqualStrings("file", served.header("X-Publr-Served").?);
    try std.testing.expect(served.header("ETag") != null);

    const tag = served.header("ETag").?;
    const revalidate = try harness.flow.head(
        "GET /posts/first HTTP/1.1\r\nHost: h\r\nIf-None-Match: {s}\r\n\r\n",
        .{tag},
    );
    const not_modified = try harness.flow.call(revalidate, "");
    try std.testing.expectEqual(@as(u16, 304), not_modified.status.code());

    // A second post: the queue holds its keys; after the quiet period the flush
    // builds its page and rewrites the listing and the home page.
    _ = try harness.publish("Second");

    const later = sdk.context.wall_clock_ms(std.testing.io) + deps.quiet_ms + 1;
    try std.testing.expect(rebuild.due(project, later));
    rebuild.flush(project, later);
    try std.testing.expect(!rebuild.due(project, later));

    const second = build.built_page(harness.app, arena, "/posts/second").?;
    try std.testing.expect(contains(second, "<code>second</code>"));

    const listing = build.built_page(harness.app, arena, "/posts").?;
    try std.testing.expect(contains(listing, "Second"));
    try std.testing.expect(contains(listing, "First"));
}

test "refresh: a current build is left alone, a publish rebuilds its pages, another app all" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();

    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();

    harness.app.output = scratch.dir;
    defer harness.app.output = null;

    _ = try harness.publish("First");

    const project = &harness.flow.project;
    const io = std.testing.io;

    // No marker: the folder is built whole, and the marker is left behind.
    const first = try rebuild.refresh(project);
    try std.testing.expectEqual(rebuild.Outcome.built, first.outcome);
    try std.testing.expect(first.full.pages >= 6);
    try std.testing.expect(rebuild.marker_matches(harness.app));

    // Nothing changed: nothing is rendered, nothing written.
    const again = try rebuild.refresh(project);
    try std.testing.expectEqual(rebuild.Outcome.current, again.outcome);
    try std.testing.expectEqual(@as(u32, 0), again.written);

    // A publish while no server ran: only what read the change is rendered again.
    _ = try harness.publish("Second");

    const after = try rebuild.refresh(project);
    try std.testing.expectEqual(rebuild.Outcome.refreshed, after.outcome);
    try std.testing.expect(after.written >= 1);
    try std.testing.expect(after.written < first.full.pages);
    try std.testing.expectEqual(@as(u32, 0), after.removed);

    const arena = harness.arena_state.allocator();
    const second = build.built_page(harness.app, arena, "/posts/second").?;
    try std.testing.expect(contains(second, "<code>second</code>"));
    const settled = try rebuild.refresh(project);
    try std.testing.expectEqual(rebuild.Outcome.current, settled.outcome);

    // A folder another app (or address) built is another site: built whole.
    const foreign = "0000000000000000\n";
    try scratch.dir.writeFile(io, .{ .sub_path = rebuild.marker_path, .data = foreign });
    try std.testing.expect(!rebuild.marker_matches(harness.app));

    const other = try rebuild.refresh(project);
    try std.testing.expectEqual(rebuild.Outcome.built, other.outcome);
    try std.testing.expect(rebuild.marker_matches(harness.app));
}

test "a path mount answers below its path, with its own islands, assets and 404" {
    var harness: Harness = undefined;
    try harness.init(.{ .base_url = "http://example.test" });
    defer harness.deinit();

    _ = try harness.publish("Counted");

    const docs = try harness.get("/docs");
    try std.testing.expectEqual(@as(u16, 200), docs.status.code());
    try std.testing.expect(contains(docs.body, "The docs"));
    try std.testing.expect(contains(docs.body, "<publr-island src=\"/docs/_islands/count\""));
    try std.testing.expect(contains(docs.body, "href=\"/docs/mark.svg\""));
    try std.testing.expect(contains(docs.body, "src=\"/docs/_app/toolbar.js?v="));

    const guide = try harness.get("/docs/guide");
    try std.testing.expect(contains(guide.body, "The guide"));

    const missing = try harness.get("/docs/nope");
    try std.testing.expectEqual(@as(u16, 404), missing.status.code());
    try std.testing.expect(contains(missing.body, "Not in the docs."));

    const island = try harness.get("/docs/_islands/count");
    try std.testing.expect(contains(island.body, "1 posts on the site"));

    const sheet = try harness.get("/docs/_app/app.css");
    try std.testing.expect(contains(sheet.body, ".bg-paper"));
    try std.testing.expect(!contains(sheet.body, ".bg-canvas"));

    // A template from a shared folder, and what it imports, are the importing app's own.
    try std.testing.expect(contains(docs.body, "Made with <span class=\"tracking-widest\">Publr"));
    try std.testing.expect(contains(sheet.body, ".italic"));
    try std.testing.expect(contains(sheet.body, ".tracking-widest"));

    // A public file is at its own path under the mount; /_app/ is only what Publr generates.
    const mark = try harness.get("/docs/mark.svg");
    try std.testing.expectEqual(@as(u16, 200), mark.status.code());
    const moved = try harness.get("/docs/_app/mark.svg");
    try std.testing.expectEqual(@as(u16, 404), moved.status.code());

    // A path that only starts like the mount is the root app's.
    const near = try harness.get("/docsx");
    try std.testing.expect(contains(near.body, "Nothing lives at this address."));
}

test "a subdomain answers with its own app, whose middleware sees the path inside it" {
    var harness: Harness = undefined;
    try harness.init(.{ .base_url = "http://example.test:8080" });
    defer harness.deinit();

    const head = try harness.flow.head(
        "GET /anything HTTP/1.1\r\nHost: portal.example.test:8080\r\n\r\n",
        .{},
    );
    const portal = try harness.flow.call(head, "");
    const expected = "{\"app\":\"portal\",\"path\":\"/anything\",\"signed_in\":false}";

    try std.testing.expectEqualStrings(expected, portal.body);

    // The same path on the domain is the root app's; an unknown subdomain too.
    const domain = try harness.get("/anything");
    try std.testing.expect(contains(domain.body, "Nothing lives at this address."));

    const other = try harness.flow.head(
        "GET / HTTP/1.1\r\nHost: shop.example.test:8080\r\n\r\n",
        .{},
    );
    const home = try harness.flow.call(other, "");
    try std.testing.expect(contains(home.body, "<title>Publr</title>"));
}

test "an app that names roles sees an account holding none of them as nobody" {
    var harness: Harness = undefined;
    try harness.init(.{ .base_url = "http://example.test" });
    defer harness.deinit();

    const users = @import("../operations/user.zig");
    const sign_in = @import("../operations/sign_in.zig");
    var system = harness.inner.ctx(.system);
    const password = "correct horse battery";

    for ([_][]const u8{ "editor", "admin" }) |name| {
        const arena = harness.arena_state.allocator();
        const email = try std.fmt.allocPrint(arena, "{s}@x.test", .{name});

        _ = try registry.SDK.dispatch(&system, users.Create, .{
            .email = email,
            .display_name = name,
            .roles = &.{name},
            .password = password,
        });
    }

    const cases = [_]struct { email: []const u8, signed_in: []const u8 }{
        .{ .email = "editor@x.test", .signed_in = "true" },
        .{ .email = "admin@x.test", .signed_in = "false" },
    };

    for (cases) |case| {
        var anonymous = harness.inner.ctx(.anonymous);

        anonymous.now_ms = sdk.context.wall_clock_ms(std.testing.io);

        const session = try registry.SDK.dispatch(&anonymous, sign_in.SignIn, .{
            .email = case.email,
            .password = password,
        });
        const head = try harness.flow.head("GET / HTTP/1.1\r\nHost: portal.example.test\r\n" ++
            "Cookie: publr_session={s}\r\n\r\n", .{session.token});
        const portal = try harness.flow.call(head, "");
        const expected = try std.fmt.allocPrint(
            harness.arena_state.allocator(),
            "\"signed_in\":{s}}}",
            .{case.signed_in},
        );

        try std.testing.expect(contains(portal.body, expected));
    }
}

test "with an app on a subdomain, one sign-in holds on every app of the domain" {
    var harness: Harness = undefined;
    try harness.init(.{ .base_url = "https://example.test" });
    defer harness.deinit();

    const users = @import("../operations/user.zig");
    var system = harness.inner.ctx(.system);

    _ = try registry.SDK.dispatch(&system, users.Create, .{
        .email = "ed@x.test",
        .display_name = "Ed",
        .password = "correct horse battery",
    });

    const signed = try harness.flow.call(
        "POST /api/auth/sign-in HTTP/1.1\r\nHost: example.test\r\n" ++
            "Origin: http://example.test\r\nContent-Type: application/json\r\n" ++
            "Content-Length: 0\r\n\r\n",
        "{\"email\":\"ed@x.test\",\"password\":\"correct horse battery\"}",
    );
    const cookie = signed.header("Set-Cookie").?;

    try std.testing.expect(contains(cookie, "; Domain=example.test"));

    // No domain to share: an address keeps the cookie the host's own.
    harness.flow.project.domain = "127.0.0.1";
    try std.testing.expect(harness.flow.project.cookie_domain() == null);
}

test "every app builds into its own folder, its sitemap at its own address" {
    var harness: Harness = undefined;
    try harness.init(.{ .base_url = "https://example.test" });
    defer harness.deinit();

    _ = try harness.publish("Built");

    const summary = try build.build_all(&harness.flow.project);
    try std.testing.expectEqual(@as(u32, 0), summary.failed);

    const arena = harness.arena_state.allocator();
    const io = std.testing.io;
    const out = harness.scratch.dir;
    const docs = try out.readFileAlloc(io, "docs/index.html", arena, .limited(1 << 20));
    try std.testing.expect(contains(docs, "The docs"));
    _ = try out.readFileAlloc(io, "docs/mark.svg", arena, .limited(1 << 10));
    _ = try out.readFileAlloc(io, "docs/_app/app.css", arena, .limited(1 << 20));
    _ = try out.readFileAlloc(io, "www/posts/built/index.html", arena, .limited(1 << 20));

    const sitemap = try out.readFileAlloc(io, "docs/sitemap.xml", arena, .limited(1 << 20));
    try std.testing.expect(contains(sitemap, "<loc>https://example.test/docs/guide</loc>"));
    const sitemap_served = try harness.get("/docs/sitemap.xml");
    try std.testing.expectEqual(@as(u16, 200), sitemap_served.status.code());
    const listed = "<loc>https://example.test/docs/guide</loc>";
    try std.testing.expect(contains(sitemap_served.body, listed));

    // The app with no pages has no folder.
    try std.testing.expectError(error.FileNotFound, out.openDir(io, "portal", .{}));

    const served = try harness.get("/docs/guide");
    try std.testing.expectEqualStrings("file", served.header("X-Publr-Served").?);
}

fn query_posts(ctx: *sdk.Ctx) !record_operations.List.Out {
    return registry.SDK.dispatch(ctx, record_operations.List, .{ .type = "post" });
}

test "operation results collect empty membership and replay only committed scoped tokens" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    var system = harness.inner.ctx(.system);
    const secret = "test-secret-" ** 4;
    const scope: sdk.dependencies.Scope = .{ .project = "example", .authority = "public" };
    const initial = try query.execute(query_posts, &system, .{}, secret, scope, 60000);
    try std.testing.expectEqual(@as(usize, 0), initial.value.records.len);
    try std.testing.expect(!initial.policy.no_store);
    try std.testing.expect(initial.policy.tags.len > 0);
    const revision = initial.policy.revision;
    _ = try harness.publish("From operation bridge");
    const changed = try query.replay(&system, revision, secret, scope);
    try std.testing.expect(changed.revision > revision);
    var matched = false;

    for (changed.tags) |tag| for (initial.policy.tags) |dependency| {
        if (std.mem.eql(u8, tag, dependency)) {
            matched = true;
        }
    };

    try std.testing.expect(matched);
    const updated = try query.execute(query_posts, &system, .{}, secret, scope, 60000);
    try std.testing.expectEqual(@as(usize, 1), updated.value.records.len);
    const other = try query.replay(
        &system,
        revision,
        secret,
        .{
            .project = "example",
            .authority = "other",
        },
    );

    for (other.tags) |tag| for (changed.tags) |dependency| {
        try std.testing.expect(!std.mem.eql(u8, tag, dependency));
    };

    var transaction = try system.db.transaction();
    try harness.index.invalidate(&.{"type:post"}, system.now_ms);
    try std.testing.expectError(
        error.UncommittedRead,
        query.replay(
            &system,
            changed.revision,
            secret,
            scope,
        ),
    );
    transaction.rollback();
    const rolled_back = try query.replay(&system, changed.revision, secret, scope);
    try std.testing.expectEqual(changed.revision, rolled_back.revision);
    try std.testing.expectEqual(@as(usize, 0), rolled_back.tags.len);
}

test "visitors and `_api`: dynamic answers set the visitor, static ones never; calls refused" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();

    const island = try harness.get("/_islands/signed-in");
    const cookie = island.header("Set-Cookie") orelse "";
    try std.testing.expect(std.mem.startsWith(u8, cookie, "publr_visitor="));
    try std.testing.expect(contains(cookie, "HttpOnly; SameSite=Lax"));

    const known = try harness.flow.head("GET /_islands/signed-in HTTP/1.1\r\nHost: h\r\n" ++
        "Cookie: publr_visitor=0123456789abcdef01234567\r\n\r\n", .{});
    const kept = try harness.flow.call(known, "");
    try std.testing.expect(kept.header("Set-Cookie") == null);

    const home = try harness.get("/");
    try std.testing.expect(home.header("Set-Cookie") == null);

    const read = try harness.get("/_api/greeter/wave");
    try std.testing.expectEqual(@as(u16, 405), read.status.code());

    const json_head = "POST /_api/{s} HTTP/1.1\r\nHost: h\r\nOrigin: {s}\r\n" ++
        "Content-Type: application/json\r\nContent-Length: 2\r\nPublr-Request: 1\r\n\r\n";
    const unmarked = "POST /_api/greeter/wave HTTP/1.1\r\nHost: h\r\nOrigin: http://h\r\n" ++
        "Content-Type: application/json\r\nContent-Length: 2\r\n\r\n";
    const foreign = try harness.flow.call(try harness.flow.head(json_head, .{
        "greeter/wave", "http://evil.example",
    }), "{}");
    try std.testing.expectEqual(@as(u16, 403), foreign.status.code());

    const bare = try harness.flow.call(try harness.flow.head(unmarked, .{}), "{}");
    try std.testing.expectEqual(@as(u16, 403), bare.status.code());

    const core = try harness.flow.call(try harness.flow.head(json_head, .{
        "record/save", "http://h",
    }), "{}");
    try std.testing.expectEqual(@as(u16, 404), core.status.code());

    const odd = try harness.flow.call(try harness.flow.head(json_head, .{
        "../record/save", "http://h",
    }), "{}");
    try std.testing.expectEqual(@as(u16, 404), odd.status.code());
}
