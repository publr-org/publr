//! The static build: every non-live route of the theme to `<url>/index.html`, every static
//! island to `_islands/<key>.html`, the assets, a sitemap and the build marker under the
//! output folder. The surgical rebuild that follows a change is `rebuild.zig`.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../app/registry.zig");
const identity_module = @import("../rest/identity.zig");
const record_operations = @import("../../operations/record.zig");
const deps = @import("../../lib/deps.zig");
const engine = @import("../../theme.zig");
const context_module = @import("context.zig");
const pages = @import("pages.zig");
const rebuild = @import("rebuild.zig");
const passthrough = @import("passthrough.zig");
const Site = @import("../../app/site.zig").Site;
const Public = @import("state.zig").Public;

const Context = context_module.Context;
const Deps = context_module.Deps;
const islands_prefix = context_module.islands_prefix;

pub const page_bytes_max: u32 = 8 << 20;
pub const path_len_max: u32 = 1024;
pub const entries_per_route_max: u32 = 10_000;

pub const Summary = struct { pages: u32 = 0, islands: u32 = 0, assets: u32 = 0, bytes: u64 = 0 };

pub const Write = enum { always, when_changed };
pub const Rendered = struct { bytes: u64, wrote: bool };

/// The whole site as files. Batches pending in the index are moot afterwards and drained;
/// the marker written last says which theme built the folder.
pub fn build(public: *Public, site: *const Site) !Summary {
    std.debug.assert(public.theme.routes.len > 0);
    std.debug.assert(site.connection.transaction_depth == 0);

    if (public.output == null) {
        try public.open_output();
    }

    var summary: Summary = .{};
    const theme = public.theme;

    public.built_at = sdk.context.wall_clock_ms(site.io);

    for (theme.routes) |*route| {
        if (route.live) {
            continue;
        }

        try build_route(public, site, route, &summary);
    }

    if (theme.error_404) |index| {
        summary.bytes += try render_404(public, site, index);
        summary.pages += 1;
    }

    for (theme.islands) |*island| {
        if (!island.dynamic) {
            summary.bytes += (try render_island(public, site, island, .always)).bytes;
            summary.islands += 1;
        }
    }

    const copied = try passthrough.sync(public);

    summary.assets += copied.files;
    summary.bytes += copied.bytes;
    try write_assets(public, &summary);
    try write_sitemap(public, site);
    try drain(public, site);
    try rebuild.write_marker(public);

    return summary;
}

fn build_route(
    public: *Public,
    site: *const Site,
    route: *const engine.Route,
    summary: *Summary,
) !void {
    std.debug.assert(!route.live);
    std.debug.assert(route.pattern.len > 0);

    switch (route.kind) {
        .static => {
            const rendered = try render_url(public, site, route, route.pattern, .{}, .always);

            summary.bytes += rendered.bytes;
            summary.pages += 1;
            report_progress(route.pattern, 1, 1);
        },
        .dynamic => {
            var arena_state = std.heap.ArenaAllocator.init(public.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const slugs = try slugs_of(public, site, arena, route);

            for (slugs, 1..) |slug, done| {
                const url = try engine.substitute(arena, route.pattern, slug);
                const params: context_module.Params = .{ .slug = slug };

                report_progress(url, @intCast(done), @intCast(slugs.len));

                const rendered = try render_url(public, site, route, url, params, .always);

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
    public: *const Public,
    site: *const Site,
    arena: std.mem.Allocator,
    route: *const engine.Route,
) ![]const []const u8 {
    std.debug.assert(route.kind == .dynamic);
    std.debug.assert(route.template < public.theme.templates.len);

    const template = public.theme.templates[route.template];
    const type_id = entry_type_of(&template) orelse return &.{};
    var sdk_ctx = identity_module.context(site, arena, .anonymous);
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

fn write_assets(public: *const Public, summary: *Summary) !void {
    std.debug.assert(public.css.len > 0);
    std.debug.assert(public.output != null);

    var arena_state = std.heap.ArenaAllocator.init(public.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (public.assets) |file| {
        const path = try std.fmt.allocPrint(arena, "theme/{s}", .{file.path});

        try write_artifact(public, path, file.data);
        summary.assets += 1;
        summary.bytes += file.data.len;
    }

    try write_artifact(public, "theme/theme.css", public.css);
    summary.assets += 1;
    summary.bytes += public.css.len;
}

fn write_artifact(public: *const Public, path: []const u8, data: []const u8) !void {
    std.debug.assert(path.len > 0);

    if (path.len > path_len_max) {
        return error.NameTooLong;
    }

    const out = public.output.?;

    if (std.mem.lastIndexOfScalar(u8, path, '/')) |cut| {
        try out.createDirPath(public.io, path[0..cut]);
    }

    try out.writeFile(public.io, .{ .sub_path = path, .data = data });
}

/// Renders a route at `url` to `<url>/index.html`, records what it read, and writes the
/// file unless the bytes are unchanged.
pub fn render_url(
    public: *Public,
    site: *const Site,
    route: *const engine.Route,
    url: []const u8,
    params: context_module.Params,
    when: Write,
) !Rendered {
    std.debug.assert(url.len > 0);
    std.debug.assert(url[0] == '/');

    var arena_state = std.heap.ArenaAllocator.init(public.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var recorded: Deps = .{ .arena = arena };
    const html = try pages.render_page(arena, public, route.template, .{
        .arena = arena,
        .site = site,
        .public = public,
        .params = params,
        .deps = &recorded,
    });

    try public.index.record(url, try recorded.checked());

    const unchanged = try public.index.unchanged(url, html);

    if (unchanged and when == .when_changed) {
        return .{ .bytes = html.len, .wrote = false };
    }

    try write_artifact(public, try page_path(arena, url), html);

    return .{ .bytes = html.len, .wrote = true };
}

/// The 404 page: built, never indexed, refreshed with every full build.
fn render_404(public: *Public, site: *const Site, index: u32) !u64 {
    std.debug.assert(index < public.theme.templates.len);
    std.debug.assert(public.output != null);

    var arena_state = std.heap.ArenaAllocator.init(public.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const html = try pages.render_page(arena, public, index, .{
        .arena = arena,
        .site = site,
        .public = public,
    });

    try write_artifact(public, "404.html", html);

    return html.len;
}

/// A static island to `_islands/<key>.html`, its reads recorded under its URL.
pub fn render_island(
    public: *Public,
    site: *const Site,
    island: *const engine.Island,
    when: Write,
) !Rendered {
    std.debug.assert(!island.dynamic);
    std.debug.assert(island.key.len > 0);

    var arena_state = std.heap.ArenaAllocator.init(public.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var recorded: Deps = .{ .arena = arena };
    const html = try pages.render_fragment(arena, public, island, .{
        .arena = arena,
        .site = site,
        .public = public,
        .deps = &recorded,
    });
    const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ islands_prefix, island.key });

    try public.index.record(url, try recorded.checked());

    const unchanged = try public.index.unchanged(url, html);

    if (unchanged and when == .when_changed) {
        return .{ .bytes = html.len, .wrote = false };
    }

    try write_artifact(public, try island_path(arena, island.key), html);

    return .{ .bytes = html.len, .wrote = true };
}

const batches_per_drain_max: u32 = 1024;

/// After a full build every pending batch is already reflected in the files.
fn drain(public: *Public, site: *const Site) !void {
    std.debug.assert(public.output != null);
    std.debug.assert(site.connection.transaction_depth == 0);

    var arena_state = std.heap.ArenaAllocator.init(public.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const later = sdk.context.wall_clock_ms(site.io) + deps.quiet_ms;
    var batches: u32 = 0;

    while (batches < batches_per_drain_max) : (batches += 1) {
        const batch = (try public.index.take(arena, later)) orelse return;

        try public.index.done(batch);
    }
}

/// A built page for `serve`, or null when it was never built.
pub fn built_page(public: *const Public, arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
    std.debug.assert(path.len > 0);
    std.debug.assert(page_bytes_max > 0);

    const out = public.output orelse return null;

    if (std.mem.indexOf(u8, path, "/.") != null) {
        return null;
    }

    const file = page_path(arena, path) catch return null;

    return out.readFileAlloc(public.io, file, arena, .limited(page_bytes_max)) catch null;
}

/// A built static island for `serve`, or null when it was never built.
pub fn built_island(public: *const Public, arena: std.mem.Allocator, key: []const u8) ?[]const u8 {
    std.debug.assert(key.len > 0);
    std.debug.assert(page_bytes_max > 0);

    const out = public.output orelse return null;
    const file = island_path(arena, key) catch return null;

    return out.readFileAlloc(public.io, file, arena, .limited(page_bytes_max)) catch null;
}

pub fn built_404(public: *const Public, arena: std.mem.Allocator) ?[]const u8 {
    std.debug.assert(page_bytes_max > 0);
    std.debug.assert(public.css.len > 0);

    const out = public.output orelse return null;

    return out.readFileAlloc(public.io, "404.html", arena, .limited(page_bytes_max)) catch null;
}

pub fn write_sitemap(public: *Public, site: *const Site) !void {
    std.debug.assert(public.output != null);
    std.debug.assert(public.options.base_url.len > 0);

    var arena_state = std.heap.ArenaAllocator.init(public.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var xml: std.Io.Writer.Allocating = .init(arena);
    const writer = &xml.writer;
    const base = public.options.base_url;

    try writer.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
        "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n");

    for (public.theme.routes) |*route| {
        switch (route.kind) {
            .static => {
                const priority: []const u8 = if (route.pattern.len <= 1) "1.0" else "0.8";

                try sitemap_url(writer, base, route.pattern, if (route.live) "0.5" else priority);
            },
            .dynamic => {
                for (try slugs_of(public, site, arena, route)) |slug| {
                    const url = try engine.substitute(arena, route.pattern, slug);

                    try sitemap_url(writer, base, url, "0.6");
                }
            },
            .catch_all => {},
        }
    }

    try writer.writeAll("</urlset>\n");
    try write_artifact(public, "sitemap.xml", xml.written());
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

/// "/posts/hello" is "posts/hello/index.html"; "/" is "index.html".
fn page_path(arena: std.mem.Allocator, url: []const u8) ![]const u8 {
    std.debug.assert(url.len > 0);
    std.debug.assert(url[0] == '/');

    if (url.len <= 1) {
        return "index.html";
    }

    return std.fmt.allocPrint(arena, "{s}/index.html", .{url[1..]});
}

/// "latest-posts" is "_islands/latest-posts.html".
pub fn island_path(arena: std.mem.Allocator, key: []const u8) ![]const u8 {
    std.debug.assert(key.len > 0);
    std.debug.assert(std.mem.indexOfScalar(u8, key, '/') == null);

    return std.fmt.allocPrint(arena, "_islands/{s}.html", .{key});
}

test "artifact file paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("index.html", try page_path(arena, "/"));
    const post = try page_path(arena, "/posts/hello");
    try std.testing.expectEqualStrings("posts/hello/index.html", post);
    const island = try island_path(arena, "latest-posts");
    try std.testing.expectEqualStrings("_islands/latest-posts.html", island);
}
