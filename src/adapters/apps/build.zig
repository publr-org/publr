//! The static build: every non-live route of an app to `<url>/index.html`, every static
//! island to `_islands/<key>.html`, the assets, a sitemap and the build marker under the
//! app's output folder, `<output>/<app>/`. The surgical rebuild that follows a change is
//! `rebuild.zig`.

const std = @import("std");
const report = @import("../../lib/report.zig");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const identity_module = @import("../rest/identity.zig");
const record_operations = @import("../../operations/record.zig");
const deps = @import("../../lib/deps.zig");
const engine = @import("../../template.zig");
const context_module = @import("context.zig");
const pages = @import("pages.zig");
const rebuild = @import("rebuild.zig");
const public = @import("public.zig");
const artifacts = @import("artifacts.zig");
const Project = @import("../../server/project.zig").Project;
const App = @import("state.zig").App;

const Context = context_module.Context;
const Deps = context_module.Deps;
const islands_prefix = context_module.islands_prefix;

pub const entries_per_route_max: u32 = 10_000;
pub const built_page = artifacts.built_page;
pub const built_island = artifacts.built_island;
pub const built_404 = artifacts.built_404;

pub const Summary = struct {
    pages: u32 = 0,
    islands: u32 = 0,
    assets: u32 = 0,
    bytes: u64 = 0,
    /// Apps whose build failed: they answer 503 until a later build succeeds.
    failed: u32 = 0,
};

pub const Write = enum { always, when_changed };
pub const Rendered = struct { bytes: u64, wrote: bool };

/// Every app as files. Batches pending in the index are moot afterwards and drained.
pub fn build_all(project: *const Project) !Summary {
    std.debug.assert(project.connection.transaction_depth == 0);
    std.debug.assert(project.apps.len > 0);

    var total: Summary = .{};

    for (project.apps) |*app| {
        const summary = build_or_fail(app, project);

        total.pages += summary.pages;
        total.islands += summary.islands;
        total.assets += summary.assets;
        total.bytes += summary.bytes;
        total.failed += summary.failed;
    }

    try drain(project);

    return total;
}

/// One app built, or marked unavailable when it cannot be: the other apps and the admin
/// stay up, and a later write retries it.
pub fn build_or_fail(app: *App, project: *const Project) Summary {
    std.debug.assert(project.connection.transaction_depth == 0);
    std.debug.assert(app.css.len > 0);

    const summary = build(app, project) catch |err| {
        fail(app, err);

        return .{ .failed = 1 };
    };

    app.build_ready = true;

    return summary;
}

/// The app's pages answer 503 until a build after the next write succeeds.
pub fn fail(app: *App, err: anyerror) void {
    std.debug.assert(app.spec.name.len > 0);
    std.debug.assert(@errorName(err).len > 0);

    app.build_ready = false;
    app.retry_revision = app.index.revision() catch 0;

    const cause = if (app.options.diagnostic) |reason| reason.text() else "";

    report.warn_reason(cause, "publr: app {s} did not build: {s}; its pages answer 503, " ++
        "the admin and the other apps stay up", .{ app.spec.name, @errorName(err) });
}

/// One app as files; the marker written last says what built the folder. An app without
/// pages has nothing to build.
pub fn build(app: *App, project: *const Project) !Summary {
    std.debug.assert(project.connection.transaction_depth == 0);
    std.debug.assert(app.css.len > 0);

    const program = app.program orelse return .{};

    if (app.output == null) {
        try app.open_output();
    }

    var summary: Summary = .{};

    app.built_at = sdk.context.wall_clock_ms(project.io);

    for (program.routes) |*route| {
        if (route.live) {
            continue;
        }

        try build_route(app, project, route, &summary);
    }

    if (program.error_404) |index| {
        summary.bytes += try render_404(app, project, index);
        summary.pages += 1;
    }

    for (program.islands) |*island| {
        if (!island.dynamic) {
            summary.bytes += (try render_island(app, project, island, .always)).bytes;
            summary.islands += 1;
        }
    }

    const copied = try public.sync(app);

    summary.assets += copied.files;
    summary.bytes += copied.bytes;
    try write_assets(app, &summary);
    try write_sitemap(app, project);
    try rebuild.write_marker(app);

    return summary;
}

fn build_route(
    app: *App,
    project: *const Project,
    route: *const engine.Route,
    summary: *Summary,
) !void {
    std.debug.assert(!route.live);
    std.debug.assert(route.pattern.len > 0);

    switch (route.kind) {
        .static => {
            const rendered = try render_url(app, project, route, route.pattern, .{}, .always);

            summary.bytes += rendered.bytes;
            summary.pages += 1;
            report_progress(route.pattern, 1, 1);
        },
        .dynamic => {
            var arena_state = std.heap.ArenaAllocator.init(app.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const slugs = try slugs_of(app, project, arena, route);

            for (slugs, 1..) |slug, done| {
                const url = try engine.substitute(arena, route.pattern, slug);
                const params: context_module.Params = .{ .slug = slug };

                report_progress(url, @intCast(done), @intCast(slugs.len));

                const rendered = try render_url(app, project, route, url, params, .always);

                summary.bytes += rendered.bytes;
                summary.pages += 1;
            }

            if (slugs.len > 0) {
                std.debug.print("\n", .{});
            }
        },
        .catch_all => {},
    }
}

/// What the build is on: the page about to render, one line per route rewritten as it
/// goes (a site of hundreds of pages would otherwise sit silent for minutes). The line
/// is cleared to its end so a shorter URL leaves no tail of the longer one before it.
fn report_progress(url: []const u8, done: u32, total: u32) void {
    std.debug.assert(url.len > 0);
    std.debug.assert(done <= total);

    std.debug.print("\rpublr: building {s} ({d}/{d})\x1b[K", .{ url, done, total });

    if (total == 1) {
        std.debug.print("\n", .{});
    }
}

/// The slugs a `[slug]` route has pages for: the live records of the type its template
/// reads with `getEntry()`; none when it reads no entry.
fn slugs_of(
    app: *const App,
    project: *const Project,
    arena: std.mem.Allocator,
    route: *const engine.Route,
) ![]const []const u8 {
    std.debug.assert(route.kind == .dynamic);
    std.debug.assert(route.template < app.pages().templates.len);

    const template = app.pages().templates[route.template];
    const type_id = entry_type_of(&template) orelse return &.{};
    var sdk_ctx = identity_module.context(project, arena, .anonymous);
    var slugs: std.ArrayList([]const u8) = .empty;
    var offset: u32 = 0;

    while (offset < entries_per_route_max) : (offset += record_operations.list_max) {
        const listed = registry.SDK.dispatch(&sdk_ctx, record_operations.List, .{
            .type = type_id,
            .order = .created_desc,
            .limit = record_operations.list_max,
            .offset = offset,
        }) catch |err| switch (err) {
            error.NotFound => return &.{},
            else => return err,
        };

        for (listed.records) |record| {
            const slug = record.slug orelse continue;

            try slugs.append(arena, slug);
        }

        if (listed.records.len < record_operations.list_max) {
            break;
        }
    }

    return slugs.items;
}

/// The type a template's `Publr.build.getEntry()` reads, from its frontmatter.
pub fn entry_type_of(template: *const engine.Template) ?[]const u8 {
    std.debug.assert(template.compiled);
    std.debug.assert(template.rel.len > 0);

    for (template.decls) |decl| {
        switch (decl.value) {
            .entry => |entry| return entry.type_id,
            else => {},
        }
    }

    return null;
}

fn write_assets(app: *const App, summary: *Summary) !void {
    std.debug.assert(app.css.len > 0);
    std.debug.assert(app.output != null);

    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (app.assets) |file| {
        const path = try std.fmt.allocPrint(arena, "_app/{s}", .{file.path});

        try artifacts.write(app, path, file.data);
        summary.assets += 1;
        summary.bytes += file.data.len;
    }

    try artifacts.write(app, "_app/" ++ context_module.stylesheet, app.css);
    summary.assets += 1;
    summary.bytes += app.css.len;
}

/// Renders a route at `url` to `<url>/index.html`, records what it read, and writes the
/// file unless the bytes are unchanged.
pub fn render_url(
    app: *App,
    project: *const Project,
    route: *const engine.Route,
    url: []const u8,
    params: context_module.Params,
    when: Write,
) !Rendered {
    std.debug.assert(url.len > 0);
    std.debug.assert(url[0] == '/');

    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var recorded: Deps = .{ .arena = arena, .app = app.spec.name };
    const html = try pages.render_page(arena, app, route.template, .{
        .arena = arena,
        .project = project,
        .app = app,
        .params = params,
        .deps = &recorded,
    });

    const artifact = try artifacts.name(arena, app, url);

    try app.index.record(artifact, try recorded.checked());

    const unchanged = try app.index.unchanged(artifact, html);

    if (unchanged and when == .when_changed) {
        return .{ .bytes = html.len, .wrote = false };
    }

    try artifacts.write(app, try artifacts.page_path(arena, url), html);

    return .{ .bytes = html.len, .wrote = true };
}

/// The 404 page: built, never indexed, refreshed with every full build.
fn render_404(app: *App, project: *const Project, index: u32) !u64 {
    std.debug.assert(index < app.pages().templates.len);
    std.debug.assert(app.output != null);

    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const html = try pages.render_page(arena, app, index, .{
        .arena = arena,
        .project = project,
        .app = app,
    });

    try artifacts.write(app, "404.html", html);

    return html.len;
}

/// A static island to `_islands/<key>.html`, its reads recorded under its URL.
pub fn render_island(
    app: *App,
    project: *const Project,
    island: *const engine.Island,
    when: Write,
) !Rendered {
    std.debug.assert(!island.dynamic);
    std.debug.assert(island.key.len > 0);

    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var recorded: Deps = .{ .arena = arena, .app = app.spec.name };
    const html = try pages.render_fragment(arena, app, island, .{
        .arena = arena,
        .project = project,
        .app = app,
        .deps = &recorded,
    });
    const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ islands_prefix, island.key });
    const artifact = try artifacts.name(arena, app, url);

    try app.index.record(artifact, try recorded.checked());

    const unchanged = try app.index.unchanged(artifact, html);

    if (unchanged and when == .when_changed) {
        return .{ .bytes = html.len, .wrote = false };
    }

    try artifacts.write(app, try artifacts.island_path(arena, island.key), html);

    return .{ .bytes = html.len, .wrote = true };
}

const batches_per_drain_max: u32 = 1024;

/// After a full build every pending batch is already reflected in the files.
fn drain(project: *const Project) !void {
    std.debug.assert(project.connection.transaction_depth == 0);
    std.debug.assert(project.apps.len > 0);

    const index = project.apps[0].index;
    var arena_state = std.heap.ArenaAllocator.init(project.apps[0].gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const later = sdk.context.wall_clock_ms(project.io) + deps.quiet_ms;
    var batches: u32 = 0;

    while (batches < batches_per_drain_max) : (batches += 1) {
        const batch = (try index.take(arena, later)) orelse return;

        try index.done(batch);
    }
}

pub fn write_sitemap(app: *App, project: *const Project) !void {
    std.debug.assert(app.output != null);
    std.debug.assert(app.url.len > 0);

    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var xml: std.Io.Writer.Allocating = .init(arena);
    const writer = &xml.writer;
    const base = app.url;

    try writer.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
        "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n");

    for (app.pages().routes) |*route| {
        switch (route.kind) {
            .static => {
                const priority: []const u8 = if (route.pattern.len <= 1) "1.0" else "0.8";

                try sitemap_url(writer, base, route.pattern, if (route.live) "0.5" else priority);
            },
            .dynamic => {
                for (try slugs_of(app, project, arena, route)) |slug| {
                    const url = try engine.substitute(arena, route.pattern, slug);

                    try sitemap_url(writer, base, url, "0.6");
                }
            },
            .catch_all => {},
        }
    }

    try writer.writeAll("</urlset>\n");
    try artifacts.write(app, "sitemap.xml", xml.written());
}

fn sitemap_url(
    writer: *std.Io.Writer,
    base: []const u8,
    path: []const u8,
    priority: []const u8,
) !void {
    std.debug.assert(path.len > 0);
    std.debug.assert(priority.len == 3);

    try writer.print("  <url>\n    <loc>{s}{s}</loc>\n    <priority>{s}</priority>\n  </url>\n", .{
        base,
        path,
        priority,
    });
}
