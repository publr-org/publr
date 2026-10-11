//! What an app's files say about its design: which app is meant, the routes whose file marks
//! a template region, the template parts its files place, a record's page as the files
//! render it, and the patterns in its `design/patterns/`.
const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const identity_module = @import("../../rest/identity.zig");
const record_operations = @import("../../../operations/record.zig");
const apps_operations = @import("../../../operations/apps.zig");
const design = @import("../../../model/design.zig");
const engine = @import("../../../template.zig");
const pages = @import("../../apps/pages.zig");
const PageContext = @import("../../apps/context.zig").Context;
const build = @import("../../apps/build.zig");
const App = @import("../../apps/state.zig").App;

const Session = admin.Session;
const regions = engine.regions;

pub const patterns_max: u32 = 256;

/// The app named, else the one the admin is narrowed to, else the project's only one.
pub fn app_of(session: *const Session, named: ?[]const u8) ?*const App {
    std.debug.assert(session.signed_in());
    std.debug.assert(session.project.apps.len <= 1024);

    if (named) |name| {
        if (name.len > 0) {
            return session.project.find(name);
        }
    }

    switch (admin.app_scope.of(session)) {
        .app => |app| return app,
        .all => {},
    }

    return if (session.project.apps.len == 1) &session.project.apps[0] else null;
}

/// The apps the Design pages list: the one the admin is narrowed to, else every one.
pub fn listed_apps(session: *const Session) []const App {
    std.debug.assert(session.signed_in());
    std.debug.assert(session.project.apps.len <= 1024);

    return switch (admin.app_scope.of(session)) {
        .app => |app| app[0..1],
        .all => session.project.apps,
    };
}

fn whole(text: []const u8) regions.Range {
    std.debug.assert(text.len < 1 << 31);

    return .{
        .start = 0,
        .end = @intCast(text.len),
    };
}

/// Whether the template's own file marks a template region.
pub fn marks_region(template: *const engine.Template) bool {
    std.debug.assert(template.rel.len > 0);

    const source = template.source;

    return regions.find(source, whole(source), regions.template_attribute, null) != null;
}

/// Every route of the app whose file marks a template region, by its file.
pub fn templated_routes(arena: std.mem.Allocator, app: *const App) ![]const []const u8 {
    std.debug.assert(app.spec.name.len > 0);

    const program = app.program orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;

    for (program.routes) |route| {
        const template = &program.templates[route.template];

        if (marks_region(template)) {
            try out.append(arena, template.rel);
        }
    }

    std.debug.assert(out.items.len <= program.routes.len);

    return out.items;
}

/// Every template part name the app's files place, each once, in the order first met.
pub fn part_names(arena: std.mem.Allocator, app: *const App) ![]const []const u8 {
    std.debug.assert(app.spec.name.len > 0);

    const program = app.program orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var buffer: [regions.named_max]regions.Named = undefined;

    for (program.templates) |template| {
        const source = template.source;
        const placed = regions.list(source, whole(source), &.{regions.part_attribute}, &buffer);

        for (placed) |part| {
            if (design.valid_name(part.name) and !contains(out.items, part.name)) {
                try out.append(arena, part.name);
            }
        }
    }

    return out.items;
}

pub fn contains(names: []const []const u8, name: []const u8) bool {
    std.debug.assert(name.len <= 1 << 20);

    for (names) |known| {
        if (std.mem.eql(u8, known, name)) {
            return true;
        }
    }

    return false;
}

/// The content type a `[slug]` route's page shows a record of, if it is one.
pub fn shown_type(app: *const App, route: *const engine.Route) ?[]const u8 {
    std.debug.assert(app.spec.name.len > 0);
    std.debug.assert(app.program == null or route.template < app.program.?.templates.len);

    const program = app.program orelse return null;

    if (route.kind != .dynamic) {
        return null;
    }

    return build.entry_type_of(&program.templates[route.template]);
}

/// The `[slug]` route of the app whose page shows a record of the type, if it has one.
pub fn route_of(app: *const App, handle: []const u8) ?*const engine.Route {
    std.debug.assert(handle.len > 0);

    const program = app.program orelse return null;

    std.debug.assert(program.templates.len > 0);

    for (program.routes) |*route| {
        if (route.kind != .dynamic) {
            continue;
        }

        const read = build.entry_type_of(&program.templates[route.template]) orelse continue;

        if (std.mem.eql(u8, read, handle)) {
            return route;
        }
    }

    return null;
}

/// The record the editor fills, as its route's page reads it when no published record can
/// stand in: a saved one's edit copy, else (a new record) the type's defaults, untitled.
pub const Shown = struct {
    handle: []const u8,
    slug: ?[]const u8 = null,
    /// Empty for a new record.
    id: []const u8 = "",
    title: []const u8 = "",
    document: ?std.json.Value = null,
};

/// The page at `route` as its files render it: for the published record whose slug is
/// `shown.slug`, else the newest published one, else for `shown` itself. Null when even
/// that fails to render.
pub fn rendered(
    session: *const Session,
    app: *const App,
    route: *const engine.Route,
    shown: Shown,
) !?[]const u8 {
    std.debug.assert(shown.handle.len > 0);
    std.debug.assert(route.template < app.pages().templates.len);

    if (shown.slug) |own| {
        const own_page = render_at(session, app, route, own) catch null;

        if (own_page) |html| {
            return html;
        }
    }

    if (try newest_slug(session, shown.handle)) |newest| {
        const newest_page = render_at(session, app, route, newest) catch null;

        if (newest_page) |html| {
            return html;
        }
    }

    return render_shown(session, app, route, shown) catch null;
}

fn newest_slug(session: *const Session, handle: []const u8) !?[]const u8 {
    std.debug.assert(handle.len > 0);
    std.debug.assert(session.signed_in());

    var ctx = identity_module.context(session.project, session.arena, .anonymous);
    const listed = registry.SDK.dispatch(&ctx, record_operations.List, .{
        .type = handle,
        .order = .updated_desc,
        .limit = 1,
    }) catch return null;

    return if (listed.records.len > 0) listed.records[0].slug else null;
}

fn render_at(
    session: *const Session,
    app: *const App,
    route: *const engine.Route,
    slug: []const u8,
) ![]const u8 {
    std.debug.assert(slug.len > 0);
    std.debug.assert(session.signed_in());

    return pages.render_file_page(session.arena, app, route.template, page_context(
        session,
        app,
        route,
        slug,
    ));
}

/// The route drawn for the record the editor fills, not read from the published ones.
fn render_shown(
    session: *const Session,
    app: *const App,
    route: *const engine.Route,
    shown: Shown,
) ![]const u8 {
    std.debug.assert(shown.handle.len > 0);
    std.debug.assert(session.signed_in());

    const arena = session.arena;
    const fields = if (shown.document) |document|
        (if (document == .object) document else null)
    else
        null;
    var entry = try pages.stand_in(arena, shown.handle, fields);

    entry.id = shown.id;
    entry.slug = shown.slug;
    entry.title = shown.title;

    const context = page_context(session, app, route, shown.slug);

    return pages.render_shown(arena, app, route.template, context, entry);
}

fn page_context(
    session: *const Session,
    app: *const App,
    route: *const engine.Route,
    slug: ?[]const u8,
) PageContext {
    std.debug.assert(session.signed_in());
    std.debug.assert(route.template < app.pages().templates.len);

    return .{
        .arena = session.arena,
        .project = session.project,
        .app = app,
        .request = if (route.live) session.request else null,
        .params = .{
            .slug = slug,
        },
        .live = route.live,
    };
}

/// A pattern file of the app, by its name.
pub const FilePattern = struct {
    name: []const u8,
    pattern: design.Pattern,
};

/// `<app folder>/design/patterns/<name>.html`, read as the system: the app's own files.
pub fn file_patterns(session: *const Session, app: *const App) ![]const FilePattern {
    std.debug.assert(session.signed_in());
    std.debug.assert(app.spec.folder.len > 0);

    const arena = session.arena;
    var ctx = identity_module.context(session.project, arena, .system);
    const listed = registry.SDK.dispatch(&ctx, apps_operations.Files, .{}) catch return &.{};
    const prefix = try std.fmt.allocPrint(arena, "{s}/design/patterns/", .{app.spec.folder});
    var out: std.ArrayList(FilePattern) = .empty;

    for (listed.files) |file| {
        const inside = std.mem.startsWith(u8, file.path, prefix);
        const rest = if (inside) file.path[prefix.len..] else "";

        if (!std.mem.endsWith(u8, rest, ".html") or out.items.len == patterns_max) {
            continue;
        }

        const name = rest[0 .. rest.len - ".html".len];

        if (!design.valid_name(name)) {
            continue;
        }

        const read = registry.SDK.dispatch(&ctx, apps_operations.Read, .{
            .path = file.path,
        });
        const content = (read catch continue).content;

        try out.append(arena, .{
            .name = name,
            .pattern = design.parse_pattern(content),
        });
    }

    return out.items;
}
