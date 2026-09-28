//! The public site: the theme's routes mounted as the router's fallback, the island
//! fragments, the theme's assets, and the caching policy every response carries.

const std = @import("std");
const http = @import("../lib/http.zig");
const state = @import("site/state.zig");
const pages = @import("site/pages.zig");
const islands = @import("site/islands.zig");
const assets = @import("site/assets.zig");
const toolbar = @import("site/toolbar.zig");

pub const query = @import("site/query.zig");
pub const context = @import("site/context.zig");
pub const build = @import("site/build.zig");
pub const rebuild = @import("site/rebuild.zig");
pub const middleware = @import("site/middleware.zig");
pub const edge = @import("site/edge.zig");
pub const Public = state.Public;
pub const Options = state.Options;
pub const valid_options = state.valid_options;
pub const check_theme = state.check_theme;
pub const theme_name = state.name;
pub const pjsx_renders = state.pjsx_renders;
pub const routes_count: u32 = 3;

const Request = http.Request;
const Response = http.Response;
const Error = http.Error;

pub fn register(router: *http.Router) void {
    std.debug.assert(router.routes_len < 256 - routes_count);

    const before = router.routes_len;

    router.get("/_islands/*", &islands.island);
    router.get("/theme/*", &assets.serve);
    router.get(toolbar.toolbar_path, &toolbar.toolbar);
    router.not_found = &pages.dispatch;

    std.debug.assert(router.routes_len == before + routes_count);
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

pub fn serve_as(response: *Response, public: *const Public, served: Served) Error!void {
    std.debug.assert(public.css.len > 0);
    std.debug.assert(response.body.len == 0);

    try serve(response, public, served, .{});
}

pub fn serve(response: *Response, public: *const Public, served: Served, cache: Cache) Error!void {
    std.debug.assert(public.css.len > 0);
    std.debug.assert(cache.stale == 0 or served == .file);

    try response.set_header("X-Publr-Served", @tagName(served));

    if (public.options.dev) {
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
    if (served == .file and public.options.edge_max_age > 0) {
        const lifetime = try std.fmt.allocPrint(response.arena, "max-age={d}", .{
            public.options.edge_max_age,
        });

        try response.set_header("CDN-Cache-Control", lifetime);
    }
}

/// A built file with its `ETag`: a consumer that already holds these exact bytes gets
/// `304 Not Modified` and no body, which is what makes `no-cache` cheap.
pub fn serve_file(
    request: *const Request,
    response: *Response,
    public: *const Public,
    status: http.Status,
    html: []const u8,
    cache: Cache,
) Error!void {
    std.debug.assert(html.len > 0);
    std.debug.assert(response.body.len == 0);

    const hash = std.hash.Fnv1a_64.hash(html);
    const tag = try std.fmt.allocPrint(response.arena, "\"{x:0>16}\"", .{hash});

    try serve(response, public, .file, cache);
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
}

const sdk = @import("../sdk.zig");
const registry = @import("../app/registry.zig");
const routes = @import("../app/routes.zig");
const deps = @import("../lib/deps.zig");
const record_operations = @import("../operations/record.zig");

/// A database with the declared types (the hello plugin's public `greeting`), the embedded
/// theme loaded over it, and an offline app with every route mounted.
const Harness = struct {
    inner: sdk.testing.Harness,
    index: deps.Index,
    public: Public,
    flow: routes.testing.Flow,
    arena_state: std.heap.ArenaAllocator,

    fn init(harness: *Harness, options: Options) !void {
        std.debug.assert(options.output_dir.len > 0);
        std.debug.assert(options.base_url.len > 0);

        try harness.inner.init();
        errdefer harness.inner.deinit();

        harness.arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer harness.arena_state.deinit();

        const connection = &harness.inner.fixture.connection;
        const now_ms = sdk.context.wall_clock_ms(std.testing.io);

        harness.index = try deps.Index.open(connection, .{ .quiet_ms = deps.quiet_ms });
        try harness.public.init(
            std.testing.allocator,
            std.testing.io,
            &harness.index,
            options,
            now_ms,
        );
        errdefer harness.public.deinit();

        harness.flow.init(.{
            .connection = connection,
            .auth = &harness.inner.auth,
            .io = std.testing.io,
        }, harness.arena_state.allocator());
        harness.flow.site.public = &harness.public;

        var system = harness.inner.ctx(.system);
        system.now_ms = now_ms;
        try registry.SDK.bootstrap(&system);
    }

    fn deinit(harness: *Harness) void {
        harness.public.deinit();
        harness.arena_state.deinit();
        harness.inner.deinit();
    }

    fn get(harness: *Harness, path: []const u8) !http.Response {
        const head = try harness.flow.head("GET {s} HTTP/1.1\r\nHost: h\r\n\r\n", .{path});

        return harness.flow.call(head, "");
    }

    /// A live greeting; its slug comes from the note.
    fn publish(harness: *Harness, note: []const u8) ![]const u8 {
        std.debug.assert(note.len > 0);
        std.debug.assert(note.len < 200);

        var system = harness.inner.ctx(.system);
        system.now_ms = sdk.context.wall_clock_ms(std.testing.io);

        const document = try std.fmt.allocPrint(
            harness.arena_state.allocator(),
            "{{\"note\":\"{s}\"}}",
            .{note},
        );
        const created = try registry.SDK.dispatch(&system, record_operations.Create, .{
            .type = "greeting",
            .document = document,
            .status = "published",
        });

        return created.slug.?;
    }
};

fn contains(text: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, text, needle) != null;
}

test "unbuilt: the theme's routes render now, and the theme's 404 page answers the rest" {
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

    const page = try harness.get("/greetings/hello-site");
    try std.testing.expectEqual(@as(u16, 200), page.status.code());
    try std.testing.expect(contains(page.body, "sm:text-5xl\">Hello &lt;site&gt;</h1>"));
    try std.testing.expect(contains(page.body, "<code>hello-site</code>"));

    const missing = try harness.get("/greetings/nope");
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
            const listed = try request.call(record_operations.List, .{ .type = "greeting" });

            return request.json(.{
                .method = request.method(),
                .greetings = listed.records.len,
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

    harness.flow.site.middleware = &middleware_testing.run;
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
    const expected = "{\"method\":\"POST\",\"greetings\":1,\"nickname\":null}";

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
        .site = &harness.flow.site,
        .public = &harness.public,
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
        .site = &harness.flow.site,
        .public = &harness.public,
    };
    try std.testing.expectEqual(@as(usize, 0), (try shared.query("note", .{})).len);

    var visitor = shared;
    visitor.live = true;
    visitor.caller = .{ .user = .{ .id = "u_1", .role = .editor } };
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

    for (harness.public.theme.islands) |island| {
        if (!island.dynamic and std.mem.startsWith(u8, island.key, "latest-greetings")) {
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
    harness.flow.site.delivery_gates = &.{members_only};

    for ([_][]const u8{ "/", "/greetings/hidden", "/nope", "/_islands/signed-in" }) |path| {
        const refused = try harness.get(path);
        try std.testing.expectEqual(@as(u16, 403), refused.status.code());
        try std.testing.expect(contains(refused.body, "Members only"));
        try std.testing.expect(!contains(refused.body, "Hidden"));
        try std.testing.expectEqualStrings("private, no-store", refused.header("Cache-Control").?);
    }

    // The theme's assets are never gated.
    const style = try harness.get("/theme/theme.css");
    try std.testing.expectEqual(@as(u16, 200), style.status.code());

    const login_head = "POST /api/auth/sign-in HTTP/1.1\r\nHost: h\r\nOrigin: http://h\r\n" ++
        "Content-Length: 0\r\n\r\n";
    const signed = try harness.flow.call(
        login_head,
        "{\"email\":\"admin@example.com\",\"password\":\"correct horse battery\"}",
    );
    const cookie = signed.header("Set-Cookie").?;
    const pair = cookie[0..std.mem.indexOfScalar(u8, cookie, ';').?];
    const template = "GET /greetings/hidden HTTP/1.1\r\nHost: h\r\nCookie: {s}\r\n\r\n";
    const member = try harness.flow.call(try harness.flow.head(template, .{pair}), "");
    try std.testing.expectEqual(@as(u16, 200), member.status.code());
    try std.testing.expect(contains(member.body, "Hidden"));
    try std.testing.expectEqualStrings("private, no-store", member.header("Cache-Control").?);

    harness.flow.site.delivery_gates = &.{};
    const open = try harness.get("/greetings/hidden");
    try std.testing.expectEqual(@as(u16, 200), open.status.code());
}

test "assets: the stylesheet and the loader from memory, immutable under the fingerprint" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();

    const sheet = try harness.get("/theme/theme.css");
    try std.testing.expectEqual(@as(u16, 200), sheet.status.code());
    try std.testing.expect(contains(sheet.body, ".bg-canvas"));
    try std.testing.expectEqualStrings("public, max-age=3600", sheet.header("Cache-Control").?);

    const arena = harness.arena_state.allocator();
    const version: []const u8 = &harness.public.version;
    const stamped = try std.fmt.allocPrint(arena, "/theme/islands.js?v={s}", .{version});
    const loader = try harness.get(stamped);
    try std.testing.expectEqual(@as(u16, 200), loader.status.code());
    try std.testing.expect(contains(loader.body, "customElements.define('publr-island'"));
    const immutable = "public, max-age=31536000, immutable";
    try std.testing.expectEqualStrings(immutable, loader.header("Cache-Control").?);

    const runtime = try harness.get("/theme/publr.js");
    try std.testing.expectEqual(@as(u16, 200), runtime.status.code());
    try std.testing.expect(contains(runtime.body, "?v="));

    const missing = try harness.get("/theme/nope.css");
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

    harness.public.output = scratch.dir;
    defer harness.public.output = null;

    _ = try harness.publish("Edge");
    _ = try build.build(&harness.public, &harness.flow.site);

    const page = try harness.get("/greetings/edge");
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
    harness.flow.site.delivery_gates = &.{edge_testing.private_gate};
    const gated = try harness.get("/greetings/edge");
    try std.testing.expectEqualStrings("private, no-store", gated.header("Cache-Control").?);
    try std.testing.expectEqualStrings("no-store", gated.header("CDN-Cache-Control").?);
}

test "behind a CDN: built files carry their keys, a write answers with the keys it raised" {
    var harness: Harness = undefined;
    try harness.init(.{ .edge_max_age = 86_400 });
    defer harness.deinit();

    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();

    harness.public.output = scratch.dir;
    defer harness.public.output = null;

    const slug = try harness.publish("Tagged");
    _ = try build.build(&harness.public, &harness.flow.site);

    const arena = harness.arena_state.allocator();
    const page = try harness.get(try std.fmt.allocPrint(arena, "/greetings/{s}", .{slug}));
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

    // A greeting created through the API: exactly the keys it raised.
    const cookie = signed.header("Set-Cookie").?;
    const pair = cookie[0..std.mem.indexOfScalar(u8, cookie, ';').?];
    const csrf_at = std.mem.indexOf(u8, signed.body, "\"csrf\":\"").? + 8;
    const csrf = signed.body[csrf_at .. csrf_at + @import("../lib/auth.zig").csrf.token_len];
    const create = try harness.flow.head("POST /api/record/create HTTP/1.1\r\nHost: h\r\n" ++
        "Origin: http://h\r\nCookie: {s}\r\nX-Csrf-Token: {s}\r\nContent-Length: 0\r\n\r\n", .{
        pair,
        csrf,
    });
    const document = "{\"type\":\"greeting\",\"document\":\"{\\\"note\\\":\\\"More\\\"}\"," ++
        "\"status\":\"published\"}";
    const created = try harness.flow.call(create, document);
    try std.testing.expectEqual(@as(u16, 200), created.status.code());

    const changed = created.header(edge.changed_header).?;
    try std.testing.expect(contains(changed, "record:"));
    try std.testing.expect(contains(changed, "type:greeting"));

    // A read never answers with it.
    try std.testing.expect(page.header(edge.changed_header) == null);
}

test "build writes the site, serve prefers the files, a publish rewrites what read the change" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();

    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();

    harness.public.output = scratch.dir;
    defer harness.public.output = null;

    _ = try harness.publish("First");

    const site = &harness.flow.site;
    const summary = try build.build(&harness.public, site);
    try std.testing.expect(summary.pages >= 6);
    try std.testing.expect(summary.islands >= 2);
    try std.testing.expect(summary.assets >= 4);

    const arena = harness.arena_state.allocator();
    const io = std.testing.io;
    const home = try scratch.dir.readFileAlloc(io, "index.html", arena, .limited(1 << 20));
    try std.testing.expect(contains(home, ">First</a>"));
    try std.testing.expect(build.built_page(&harness.public, arena, "/greetings/first") != null);
    try std.testing.expect(build.built_page(&harness.public, arena, "/visit") == null);
    try std.testing.expect(build.built_404(&harness.public, arena) != null);

    const served = try harness.get("/greetings/first");
    try std.testing.expectEqualStrings("file", served.header("X-Publr-Served").?);
    try std.testing.expect(served.header("ETag") != null);

    const tag = served.header("ETag").?;
    const revalidate = try harness.flow.head(
        "GET /greetings/first HTTP/1.1\r\nHost: h\r\nIf-None-Match: {s}\r\n\r\n",
        .{tag},
    );
    const not_modified = try harness.flow.call(revalidate, "");
    try std.testing.expectEqual(@as(u16, 304), not_modified.status.code());

    // A second greeting: the queue holds its keys; after the quiet period the flush
    // builds its page and rewrites the listing and the home page.
    _ = try harness.publish("Second");

    const later = sdk.context.wall_clock_ms(std.testing.io) + deps.quiet_ms + 1;
    try std.testing.expect(rebuild.due(&harness.public, later));
    rebuild.flush(&harness.public, site, later);
    try std.testing.expect(!rebuild.due(&harness.public, later));

    const second = build.built_page(&harness.public, arena, "/greetings/second").?;
    try std.testing.expect(contains(second, "<code>second</code>"));

    const listing = build.built_page(&harness.public, arena, "/greetings").?;
    try std.testing.expect(contains(listing, "Second"));
    try std.testing.expect(contains(listing, "First"));
}

test "refresh: a current build is left alone, a publish rebuilds its pages, another theme all" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();

    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();

    harness.public.output = scratch.dir;
    defer harness.public.output = null;

    _ = try harness.publish("First");

    const site = &harness.flow.site;
    const io = std.testing.io;

    // No marker: the folder is built whole, and the marker is left behind.
    const first = try rebuild.refresh(&harness.public, site);
    try std.testing.expectEqual(rebuild.Outcome.built, first.outcome);
    try std.testing.expect(first.full.pages >= 6);
    try std.testing.expect(rebuild.marker_matches(&harness.public));

    // Nothing changed: nothing is rendered, nothing written.
    const again = try rebuild.refresh(&harness.public, site);
    try std.testing.expectEqual(rebuild.Outcome.current, again.outcome);
    try std.testing.expectEqual(@as(u32, 0), again.written);

    // A publish while no server ran: only what read the change is rendered again.
    _ = try harness.publish("Second");

    const after = try rebuild.refresh(&harness.public, site);
    try std.testing.expectEqual(rebuild.Outcome.refreshed, after.outcome);
    try std.testing.expect(after.written >= 1);
    try std.testing.expect(after.written < first.full.pages);
    try std.testing.expectEqual(@as(u32, 0), after.removed);

    const arena = harness.arena_state.allocator();
    const second = build.built_page(&harness.public, arena, "/greetings/second").?;
    try std.testing.expect(contains(second, "<code>second</code>"));
    const settled = try rebuild.refresh(&harness.public, site);
    try std.testing.expectEqual(rebuild.Outcome.current, settled.outcome);

    // A folder another theme (or address) built is another site: built whole.
    const foreign = "0000000000000000\n";
    try scratch.dir.writeFile(io, .{ .sub_path = rebuild.marker_path, .data = foreign });
    try std.testing.expect(!rebuild.marker_matches(&harness.public));

    const other = try rebuild.refresh(&harness.public, site);
    try std.testing.expectEqual(rebuild.Outcome.built, other.outcome);
    try std.testing.expect(rebuild.marker_matches(&harness.public));
}

fn queryGreetings(ctx: *sdk.Ctx) !record_operations.List.Out {
    return registry.SDK.dispatch(ctx, record_operations.List, .{ .type = "greeting" });
}

test "operation results collect empty membership and replay only committed scoped tokens" {
    var harness: Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();
    var system = harness.inner.ctx(.system);
    const secret = "test-secret-" ** 4;
    const scope: sdk.dependencies.Scope = .{ .site = "example", .authority = "public" };
    const initial = try query.execute(queryGreetings, &system, .{}, secret, scope, 60000);
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
    const updated = try query.execute(queryGreetings, &system, .{}, secret, scope, 60000);
    try std.testing.expectEqual(@as(usize, 1), updated.value.records.len);
    const other = try query.replay(
        &system,
        revision,
        secret,
        .{
            .site = "example",
            .authority = "other",
        },
    );

    for (other.tags) |tag| for (changed.tags) |dependency| {
        try std.testing.expect(!std.mem.eql(u8, tag, dependency));
    };

    var transaction = try system.db.transaction();
    try harness.index.invalidate(&.{"type:greeting"}, system.now_ms);
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
