//! Pages: an app's routes matched at request time (a publish that adds a page needs
//! no restart), served from the static build when one exists and rendered otherwise, and
//! the one render the server, the build and the tests all use.

const std = @import("std");
const http = @import("../../lib/http.zig");
const delivery = @import("delivery.zig");
const middleware = @import("middleware.zig");
const edge = @import("edge.zig");
const engine = @import("../../template.zig");
const apps_adapter = @import("../apps.zig");
const context_module = @import("context.zig");
const Memo = @import("context.zig").Memo;
const build = @import("build.zig");
const Project = @import("../../server/project.zig").Project;
const Target = Project.Target;
const App = @import("state.zig").App;
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

pub fn renderer(arena: std.mem.Allocator, app: *const App) Renderer {
    std.debug.assert(app.pages().templates.len > 0);
    std.debug.assert(app.pages().options.pjsx.len == app.spec.pjsx_renders.len);

    return .{
        .templates = app.pages().templates,
        .pjsx = app.spec.pjsx_renders,
        .arena = arena,
        .base = app.base(),
    };
}

/// One page of the app into `arena`.
pub fn render_page(
    arena: std.mem.Allocator,
    app: *const App,
    index: u32,
    context: Context,
) ![]const u8 {
    std.debug.assert(index < app.pages().templates.len);
    std.debug.assert(context.app == app);

    if (context.request == null) {
        if (app.options.diagnostic) |reason| reason.len = 0;
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    var memo: Memo = .{};
    var page_context = context;

    page_context.page = &app.pages().templates[index];
    page_context.memo = &memo;
    try renderer(arena, app).render(&out.writer, index, &page_context, .{});

    return out.written();
}

/// A component wrapped as the fragment the loader patches in.
pub fn render_fragment(
    arena: std.mem.Allocator,
    app: *const App,
    island: *const engine.Island,
    context: Context,
) ![]const u8 {
    std.debug.assert(island.template < app.pages().templates.len);
    std.debug.assert(context.page == null);

    if (context.request == null) {
        if (app.options.diagnostic) |reason| reason.len = 0;
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    var memo: Memo = .{};
    var fragment_context = context;

    fragment_context.memo = &memo;
    try out.writer.print("<template patchfor=\"{s}\">", .{island.key});
    try renderer(arena, app).render(&out.writer, island.template, &fragment_context, .{
        .values = island.props,
    });
    try out.writer.writeAll("</template>\n");

    return out.written();
}

/// A request for one of the app's pages: its middleware, then its routes, then its 404.
pub fn dispatch(
    project: *const Project,
    target: Target,
    request: *Request,
    response: *Response,
    ctx: *HttpContext,
) anyerror!void {
    std.debug.assert(ctx.user_data != null);
    std.debug.assert(target.path.len > 0);

    const app = target.app;

    if (try middleware.answer(project, app, target.path, ctx.arena, request, response)) {
        return;
    }

    if (!app.build_ready) {
        return unavailable(response);
    }

    if (request.method() != .get and request.method() != .head) {
        try apps_adapter.serve_as(response, app, .memory);

        return response.text(.not_found, "Not Found");
    }

    const door = try delivery.door(project, ctx.arena, request, response, .page);

    if (door == .refused) {
        return;
    }

    const program = app.program orelse {
        try apps_adapter.serve_as(response, app, .memory);

        return response.text(.not_found, "Not Found");
    };

    if (program.match(target.path)) |matched| {
        try render(project, target, matched, .ok, request, response, ctx);
    } else {
        try not_found(project, target, request, response, ctx);
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
    project: *const Project,
    target: Target,
    matched: engine.Match,
    status: http.Status,
    request: *Request,
    response: *Response,
    ctx: *HttpContext,
) !void {
    std.debug.assert(matched.route.template < target.app.pages().templates.len);
    std.debug.assert(ctx.user_data != null);

    const app = target.app;
    const route = matched.route;

    if (!route.live) {
        if (build.built_page(app, ctx.arena, target.path)) |html| {
            const cache: apps_adapter.Cache = .{ .max_age = page_max_age, .stale = page_stale };

            try edge.tag(response, app, ctx.arena, target.path);

            return apps_adapter.serve_file(request, response, app, status, html, cache);
        }
    }

    const caller: Caller = if (route.live)
        Context.visitor(project, app, ctx.arena, request)
    else
        .anonymous;
    var redirect_to: ?[]const u8 = null;
    const html = render_page(ctx.arena, app, route.template, .{
        .arena = ctx.arena,
        .project = project,
        .app = app,
        .request = request,
        .params = .{ .slug = matched.slug },
        .live = route.live,
        .caller = caller,
        .redirect_to = if (route.live) &redirect_to else null,
    }) catch |err| {
        if (err == error.EntryNotFound) {
            return not_found(project, target, request, response, ctx);
        }

        if (err == error.Redirect) {
            const path = redirect_to orelse return err;

            try apps_adapter.serve_as(response, app, .render);
            return response.redirect(.see_other, path);
        }

        return err;
    };

    try apps_adapter.serve_as(response, app, .render);
    try response.set_body(status, "text/html; charset=utf-8", html);
}

/// The app's 404 page for a path it has no page for: built when the build wrote it, else
/// rendered; the plain one when the app has none.
pub fn not_found(
    project: *const Project,
    target: Target,
    request: *Request,
    response: *Response,
    ctx: *HttpContext,
) anyerror!void {
    std.debug.assert(ctx.user_data != null);
    std.debug.assert(target.path.len > 0);

    const app = target.app;

    if (!app.build_ready) {
        return unavailable(response);
    }

    const path = target.path;
    const basename = path[(std.mem.lastIndexOfScalar(u8, path, '/') orelse 0) + 1 ..];

    // A path with an extension is something a browser asked for on its own (favicon.ico,
    // a .map): the plain 404, not the page.
    if (std.mem.indexOfScalar(u8, basename, '.') != null or app.program == null) {
        try apps_adapter.serve_as(response, app, .memory);

        return response.text(.not_found, "Not Found");
    }

    if (build.built_404(app, ctx.arena)) |html| {
        const cache: apps_adapter.Cache = .{ .max_age = page_max_age, .stale = page_stale };

        // Never indexed: whatever changes, a page might now live where it answered.
        try edge.tag(response, app, ctx.arena, null);

        return apps_adapter.serve_file(request, response, app, .not_found, html, cache);
    }

    try apps_adapter.serve_as(response, app, .render);

    const index = app.pages().error_404 orelse return response.text(.not_found, "Not Found");
    const html = try render_page(ctx.arena, app, index, .{
        .arena = ctx.arena,
        .project = project,
        .app = app,
        .request = request,
    });

    try response.set_body(.not_found, "text/html; charset=utf-8", html);
}
