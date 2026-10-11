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
const visitor = @import("visitor.zig");
const public = @import("public.zig");
const shell = @import("shell.zig");
const framed = @import("framed.zig");
const ids = @import("../../lib/id.zig");
const Project = @import("../../server/project.zig").Project;
const Target = Project.Target;
const App = @import("state.zig").App;
const Caller = @import("../../sdk.zig").Caller;

const Request = http.Request;
const Response = http.Response;
const HttpContext = http.Context;
const Context = context_module.Context;
const model_variant = @import("../../model/variant.zig");

pub const Renderer = engine.Renderer(Context);

/// How long a visitor may reuse a page without asking, and how long a shared cache may
/// serve its copy while it revalidates: the same minute a static island is kept.
pub const page_max_age: u32 = 60;
pub const page_stale: u32 = 24 * 60 * 60;

/// The renderer for a page or fragment in `place`'s language: its islands are asked for
/// under the language's address, so they read in it too.
pub fn renderer(arena: std.mem.Allocator, app: *const App, place: model_variant.Place) Renderer {
    std.debug.assert(app.pages().templates.len > 0);
    std.debug.assert(app.pages().options.pjsx.len == app.spec.pjsx_renders.len);

    const base = if (place.address.len == 0)
        app.base()
    else
        std.mem.concat(arena, u8, &.{ app.base(), place.address }) catch app.base();

    return .{
        .templates = app.pages().templates,
        .pjsx = app.spec.pjsx_renders,
        .arena = arena,
        .base = base,
    };
}

/// One page of the app into `arena`, as its design has it: the published overrides of
/// its template and template parts applied (`design.zig`).
pub fn render_page(
    arena: std.mem.Allocator,
    app: *const App,
    index: u32,
    context: Context,
) ![]const u8 {
    std.debug.assert(index < app.pages().templates.len);
    std.debug.assert(context.app == app);

    const html = try render_file_page(arena, app, index, context);
    const rel = app.pages().templates[index].rel;

    return @import("design.zig").apply(context, rel, html);
}

/// One page of the app into `arena`, as its files have it.
pub fn render_file_page(
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
    try renderer(arena, app, context.place).render(&out.writer, index, &page_context, .{});

    return out.written();
}

/// A `[slug]` page of the app as its files have it, showing `shown` where it reads its
/// entry: a record not published yet, or a new one's stand-in (`stand_in`).
pub fn render_shown(
    arena: std.mem.Allocator,
    app: *const App,
    index: u32,
    context: Context,
    shown: Context.Entry,
) ![]const u8 {
    std.debug.assert(shown.type.len > 0);
    std.debug.assert(shown.data.document == .object);

    var shown_context = context;

    shown_context.params = .{
        .slug = shown.slug orelse "",
    };
    shown_context.shown = shown;

    return render_file_page(arena, app, index, shown_context);
}

/// A new record of the type as its page reads it: no id, slug or title, `document` its
/// fields (the type's defaults), an empty one when null.
pub fn stand_in(
    arena: std.mem.Allocator,
    handle: []const u8,
    document: ?std.json.Value,
) !Context.Entry {
    std.debug.assert(handle.len > 0);
    std.debug.assert(document == null or document.? == .object);

    const fields = document orelse std.json.Value{
        .object = .empty,
    };

    return .{
        .id = "",
        .type = handle,
        .slug = null,
        .title = "",
        .created_at = "",
        .updated_at = "",
        .data = .{
            .arena = arena,
            .document = fields,
        },
    };
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
    const fragment_renderer = renderer(arena, app, context.place);

    try fragment_renderer.render(&out.writer, island.template, &fragment_context, .{
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

    switch (try shell.answer(project, target.app, ctx.arena, request, response)) {
        .plain => return serve(project, target, request, response, ctx),
        .sandboxed => {
            // The page as the frame's visitor gets it, never as the administrator.
            var buffer: [ids.len]u8 = undefined;
            const visitor_id = framed.visitor_of(project, request, &buffer);
            var as_visitor = try framed.as_visitor(project, ctx.arena, request, visitor_id);

            try serve(project, target, &as_visitor, response, ctx);
            try shell.guard(target.app, visitor_id, response);
            try shell.seal(response);
        },
    }
}

fn serve(
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

    const matched = if (app.program) |program| program.match(target.path) else null;
    const fixed_page = if (matched) |found| found.slug == null else false;

    // A page at a fixed path wins; anywhere else a public file comes before a `[slug]`
    // page and the 404, and, like every asset, is never gated.
    if (!fixed_page and try public.serve(app, target.path, request, response, ctx)) {
        return;
    }

    const door = try delivery.door(project, ctx.arena, request, response, .page);

    if (door == .refused) {
        return;
    }

    if (app.program == null) {
        try apps_adapter.serve_as(response, app, .memory);

        return response.text(.not_found, "Not Found");
    }

    if (matched) |found| {
        try render(project, target, found, .ok, request, response, ctx);
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

    const full_path = try model_variant.under(ctx.arena, target.place.address, target.path);

    if (!route.live) {
        if (build.built_page(app, ctx.arena, full_path)) |html| {
            const cache: apps_adapter.Cache = .{
                .max_age = page_max_age,
                .stale = page_stale,
            };

            try edge.tag(response, app, ctx.arena, full_path);

            return apps_adapter.serve_file(request, response, app, status, html, cache);
        }
    }

    const caller: Caller = if (route.live)
        Context.visitor(project, app, ctx.arena, request)
    else
        .anonymous;
    const visitor_id = if (route.live)
        try visitor.ensure(project, request, response, ctx.arena)
    else
        "";
    var redirect_to: ?[]const u8 = null;
    const html = render_page(ctx.arena, app, route.template, .{
        .arena = ctx.arena,
        .project = project,
        .app = app,
        .request = request,
        .params = .{
            .slug = matched.slug,
        },
        .live = route.live,
        .caller = caller,
        .visitor_id = visitor_id,
        .place = target.place,
        .route = route,
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
        const cache: apps_adapter.Cache = .{
            .max_age = page_max_age,
            .stale = page_stale,
        };

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
        .place = target.place,
    });

    try response.set_body(.not_found, "text/html; charset=utf-8", html);
}

test "render_shown: a [slug] page with nothing published draws a draft or a stand-in" {
    var harness: apps_adapter.Harness = undefined;
    try harness.init(.{});
    defer harness.deinit();

    const arena = harness.arena_state.allocator();
    const app = harness.app;
    const index = app.program.?.match("/posts/any").?.route.template;
    const context: Context = .{
        .arena = arena,
        .project = &harness.flow.project,
        .app = app,
    };
    var unpublished = context;
    unpublished.params = .{
        .slug = "any",
    };
    const missing = render_file_page(arena, app, index, unpublished);
    try std.testing.expectError(error.EntryNotFound, missing);

    const blank = try render_shown(arena, app, index, context, try stand_in(arena, "post", null));
    try std.testing.expect(std.mem.indexOf(u8, blank, "href=\"/posts\"") != null);
    const blank_text = try harness.decoded(app, blank);
    try std.testing.expect(std.mem.indexOf(u8, blank_text, "sm:text-5xl\"></h1>") != null);

    var draft = try stand_in(arena, "post", .{
        .object = .empty,
    });
    draft.slug = "my-draft";
    draft.title = "A draft";
    const drawn = try render_shown(arena, app, index, context, draft);
    const drawn_text = try harness.decoded(app, drawn);
    try std.testing.expect(std.mem.indexOf(u8, drawn_text, "sm:text-5xl\">A draft</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, drawn, "<code>my-draft</code>") != null);

    const other = render_shown(arena, app, index, context, try stand_in(arena, "note", null));
    try std.testing.expectError(error.EntryNotFound, other);
}
