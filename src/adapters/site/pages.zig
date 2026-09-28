//! Pages: the theme's routes matched at request time (a publish that adds a page needs
//! no restart), served from the static build when one exists and rendered otherwise, and
//! the one render the server, the build and the tests all use.

const std = @import("std");
const http = @import("../../lib/http.zig");
const delivery = @import("delivery.zig");
const middleware = @import("middleware.zig");
const edge = @import("edge.zig");
const engine = @import("../../theme.zig");
const site_adapter = @import("../site.zig");
const context_module = @import("context.zig");
const Memo = @import("context.zig").Memo;
const build = @import("build.zig");
const Site = @import("../../app/site.zig").Site;
const Public = @import("state.zig").Public;
const Caller = @import("../../sdk.zig").Caller;

const Request = http.Request;
const Response = http.Response;
const HttpContext = http.Context;
const Context = context_module.Context;

pub const Renderer = engine.Renderer(Context);

/// How long a visitor may reuse a page without asking, and how long a shared cache may
/// serve its copy while it revalidates: the same minute a static island is kept.
pub const page_max_age: u32 = 60;
pub const page_stale: u32 = 24 * 60 * 60;

pub fn renderer(arena: std.mem.Allocator, public: *const Public) Renderer {
    std.debug.assert(public.theme.templates.len > 0);
    std.debug.assert(public.theme.options.pjsx.len == site_adapter.pjsx_renders.len);

    return .{
        .templates = public.theme.templates,
        .pjsx = site_adapter.pjsx_renders,
        .arena = arena,
    };
}

/// One page of the theme into `arena`.
pub fn render_page(
    arena: std.mem.Allocator,
    public: *const Public,
    index: u32,
    context: Context,
) ![]const u8 {
    std.debug.assert(index < public.theme.templates.len);
    std.debug.assert(context.public == public);

    if (context.request == null) {
        if (public.options.diagnostic) |reason| reason.len = 0;
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    var memo: Memo = .{};
    var page_context = context;

    page_context.page = &public.theme.templates[index];
    page_context.memo = &memo;
    try renderer(arena, public).render(&out.writer, index, &page_context, .{});

    return out.written();
}

/// A component wrapped as the fragment the loader patches in.
pub fn render_fragment(
    arena: std.mem.Allocator,
    public: *const Public,
    island: *const engine.Island,
    context: Context,
) ![]const u8 {
    std.debug.assert(island.template < public.theme.templates.len);
    std.debug.assert(context.page == null);

    if (context.request == null) {
        if (public.options.diagnostic) |reason| reason.len = 0;
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    var memo: Memo = .{};
    var fragment_context = context;

    fragment_context.memo = &memo;
    try out.writer.print("<template patchfor=\"{s}\">", .{island.key});
    try renderer(arena, public).render(&out.writer, island.template, &fragment_context, .{
        .values = island.props,
    });
    try out.writer.writeAll("</template>\n");

    return out.written();
}

/// Every request no other route took: the theme's routes, then its 404.
pub fn dispatch(request: *Request, response: *Response, ctx: *HttpContext) anyerror!void {
    std.debug.assert(ctx.user_data != null);
    std.debug.assert(request.path().len > 0);

    const site = Site.of(ctx);

    if (try middleware.answer(site, ctx.arena, request, response)) {
        return;
    }

    const public = site.public orelse {
        if (site.public_failed) {
            return unavailable(response);
        }

        return response.text(.not_found, "Not Found");
    };

    if (!public.build_ready) {
        return unavailable(response);
    }

    if (request.method() != .get and request.method() != .head) {
        try site_adapter.serve_as(response, public, .memory);

        return response.text(.not_found, "Not Found");
    }

    const door = try delivery.door(site, ctx.arena, request, response, .page);

    if (door == .refused) {
        return;
    }

    if (public.theme.match(request.path())) |matched| {
        try render(public, site, matched, .ok, request, response, ctx);
    } else {
        try not_found(request, response, ctx);
    }

    if (door == .private) {
        try delivery.keep_private(response);
    }
}

pub fn unavailable(response: *Response) !void {
    std.debug.assert(response.body.len == 0);
    try response.set_header("Cache-Control", "no-store");
    try response.set_header("Retry-After", "60");
    return response.text(
        .service_unavailable,
        "This site is temporarily unavailable. Please try again later.",
    );
}

/// The built file when the build produced one, else rendered now: a live page, dev,
/// anything not yet built. A `[slug]` page whose entry does not exist is the 404 page.
fn render(
    public: *Public,
    site: *const Site,
    matched: engine.Match,
    status: http.Status,
    request: *Request,
    response: *Response,
    ctx: *HttpContext,
) !void {
    std.debug.assert(matched.route.template < public.theme.templates.len);
    std.debug.assert(ctx.user_data != null);

    const route = matched.route;

    if (!route.live) {
        if (build.built_page(public, ctx.arena, request.path())) |html| {
            const cache: site_adapter.Cache = .{ .max_age = page_max_age, .stale = page_stale };

            try edge.tag(response, public, ctx.arena, request.path());

            return site_adapter.serve_file(request, response, public, status, html, cache);
        }
    }

    const caller: Caller = if (route.live)
        Context.visitor(site, ctx.arena, request)
    else
        .anonymous;
    var redirect_to: ?[]const u8 = null;
    const html = render_page(ctx.arena, public, route.template, .{
        .arena = ctx.arena,
        .site = site,
        .public = public,
        .request = request,
        .params = .{ .slug = matched.slug },
        .live = route.live,
        .caller = caller,
        .redirect_to = if (route.live) &redirect_to else null,
    }) catch |err| {
        if (err == error.EntryNotFound) {
            return not_found(request, response, ctx);
        }

        if (err == error.Redirect) {
            const path = redirect_to orelse return err;

            try site_adapter.serve_as(response, public, .render);
            return response.redirect(.see_other, path);
        }

        return err;
    };

    try site_adapter.serve_as(response, public, .render);
    try response.set_body(status, "text/html; charset=utf-8", html);
}

pub fn not_found(request: *Request, response: *Response, ctx: *HttpContext) anyerror!void {
    std.debug.assert(ctx.user_data != null);
    std.debug.assert(request.path().len > 0);

    const site = Site.of(ctx);
    const public = site.public orelse {
        if (site.public_failed) {
            return unavailable(response);
        }

        return response.text(.not_found, "Not Found");
    };

    if (!public.build_ready) {
        return unavailable(response);
    }

    const path = request.path();
    const basename = path[(std.mem.lastIndexOfScalar(u8, path, '/') orelse 0) + 1 ..];

    // A path with an extension is something a browser asked for on its own (favicon.ico,
    // a .map): the plain 404, not the page.
    if (std.mem.indexOfScalar(u8, basename, '.') != null) {
        try site_adapter.serve_as(response, public, .memory);

        return response.text(.not_found, "Not Found");
    }

    if (build.built_404(public, ctx.arena)) |html| {
        const cache: site_adapter.Cache = .{ .max_age = page_max_age, .stale = page_stale };

        // Never indexed: whatever changes, a page might now live where it answered.
        try edge.tag(response, public, ctx.arena, null);

        return site_adapter.serve_file(request, response, public, .not_found, html, cache);
    }

    try site_adapter.serve_as(response, public, .render);

    const index = public.theme.error_404 orelse return response.text(.not_found, "Not Found");
    const html = try render_page(ctx.arena, public, index, .{
        .arena = ctx.arena,
        .site = site,
        .public = public,
        .request = request,
    });

    try response.set_body(.not_found, "text/html; charset=utf-8", html);
}

test "homepage context renders the published website settings and nothing less" {
    const sdk = @import("../../sdk.zig");
    const registry = @import("../../app/registry.zig");
    const records = @import("../../operations/record.zig");
    const settings = @import("../../operations/settings.zig");
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var system = harness.ctx(.system);
    try settings.ensure(&system);
    var index = try @import("../../lib/deps.zig").Index.open(system.db, .{});
    var reason: @import("../../lib/report.zig").Reason = .{};
    var public: Public = undefined;
    try public.init(std.testing.allocator, std.testing.io, &index, .{ .diagnostic = &reason }, 0);
    defer public.deinit();
    var diagnostic: engine.Diagnostic = .{ .arena = system.arena };
    const theme = try engine.load(std.testing.allocator, &.{.{
        .rel = "content/index.publr",
        .source = "---\nconst home = Publr.context.entry;\n" ++
            "const title = home.data.hero_title ?? '';\n---\n<h1>{title}</h1>",
    }}, public.theme.options, &diagnostic);
    defer std.testing.allocator.destroy(theme);
    defer theme.deinit();
    const original = public.theme;
    public.theme = theme;
    defer public.theme = original;
    const site: Site = .{ .connection = system.db, .auth = &harness.auth, .io = std.testing.io };
    var dependencies: context_module.Deps = .{ .arena = system.arena };
    const context: Context = .{
        .arena = system.arena,
        .public = &public,
        .site = &site,
        .deps = &dependencies,
    };
    try std.testing.expectError(
        error.HomepageNotSet,
        render_page(
            system.arena,
            &public,
            0,
            context,
        ),
    );
    try std.testing.expect(std.mem.indexOf(u8, reason.text(), "not published") != null);
    const record = try registry.SDK.dispatch(&system, records.Create, .{
        .type = settings.handle,
        .document = "{\"hero_title\":\"Published homepage\"}",
        .status = "published",
    });
    const html = try render_page(system.arena, &public, 0, context);
    try std.testing.expectEqualStrings("<h1>Published homepage</h1>", html);
    try std.testing.expect(dependencies.seen.contains(settings.dependency_key));
    _ = try registry.SDK.dispatch(&system, records.Transition, .{ .id = record.id, .to = "draft" });
    try std.testing.expectError(
        error.HomepageNotSet,
        render_page(
            system.arena,
            &public,
            0,
            context,
        ),
    );
}
