//! A site page as a preview draws it: any address of the project's apps, in preview mode. The
//! previewed record's own page shows the form the editor posted over its edit copy (or the
//! edit copy alone); every other record's page shows its own edit copy, so drafts and pending
//! changes read as they will once published. Every address the page draws starts with the
//! preview's base, so following a link stays in the preview. An address that is no page (a
//! stylesheet, a picture) is the site's own file.
const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const model = @import("../../../model.zig");
const sdk = @import("../../../sdk.zig");
const record_operations = @import("../../../operations/record.zig");
const types = @import("../../../operations/content_type.zig");
const engine = @import("../../../template.zig");
const http = @import("../../../lib/http.zig");
const identity_module = @import("../../rest/identity.zig");
const pages = @import("../../apps/pages.zig");
const fields = @import("../fields.zig");
const files = @import("../design/files.zig");
const App = @import("../../apps/state.zig").App;
const PageContext = @import("../../apps/context.zig").Context;
const Project = @import("../../../server/project.zig").Project;

const Def = model.content_type.Def;
const Value = std.json.Value;

/// What a preview of one address asks for.
pub const Visit = struct {
    project: *const Project,
    arena: std.mem.Allocator,
    request: *http.Request,
    /// Who opened the preview: the edit copies are read as them.
    caller: sdk.Caller,
    /// The record previewed, or `new` for one not saved yet.
    record: []const u8,
    /// The address inside the project, past the preview's base: `/kontakt`.
    path: []const u8,
    /// Where the page's addresses start: `<base>/admin/preview/<pass>/site`.
    base: []const u8,
    /// The editor's form as it stood, posted by the preview's tab.
    form: ?*const admin.Form,
};

pub const Drawn = union(enum) {
    page: []const u8,
    /// Not a page: the site's own file at this address.
    file: []const u8,
    missing,
};

pub fn draw(visit: Visit) !Drawn {
    std.debug.assert(visit.path.len > 0 and visit.path[0] == '/');
    std.debug.assert(visit.record.len > 0);

    const path = visit.path[0 .. std.mem.indexOfScalar(u8, visit.path, '?') orelse visit.path.len];
    const host = visit.request.header("host") orelse "";
    const target = visit.project.resolve(host, path) orelse return .missing;
    const app: *const App = target.app;

    if (!app.build_ready or app.program == null) {
        return .missing;
    }

    const matched = app.program.?.match(target.path) orelse {
        return .{
            .file = try std.fmt.allocPrint(visit.arena, "{s}{s}", .{
                visit.project.admin_path(),
                visit.path,
            }),
        };
    };
    const route = matched.route;
    var context: PageContext = .{
        .arena = visit.arena,
        .project = visit.project,
        .app = app,
        .request = if (route.live) visit.request else null,
        .params = .{
            .slug = matched.slug,
        },
        .live = route.live,
        .caller = visit.caller,
        .preview = true,
        .preview_base = visit.base,
    };
    const slug = matched.slug orelse {
        return .{
            .page = try pages.render_file_page(visit.arena, app, route.template, context),
        };
    };
    const handle = files.shown_type(app, route) orelse {
        return .{
            .page = try pages.render_file_page(visit.arena, app, route.template, context),
        };
    };
    const entry = try entry_at(visit, handle, slug) orelse return .missing;

    context.params = .{
        .slug = slug,
    };

    return .{
        .page = try pages.render_shown(visit.arena, app, route.template, context, entry),
    };
}

/// The record the `[slug]` page shows: the previewed one, with the posted form over it, when
/// the page is its own; else the type's record of that slug, as its edit copy reads.
fn entry_at(visit: Visit, handle: []const u8, slug: []const u8) !?PageContext.Entry {
    std.debug.assert(handle.len > 0);
    std.debug.assert(slug.len > 0);

    var ctx = identity_module.context(visit.project, visit.arena, visit.caller);

    if (try own_entry(visit, &ctx, handle, slug)) |own| {
        return own;
    }

    const listed = registry.SDK.dispatch(&ctx, record_operations.List, .{
        .type = handle,
        .slug = slug,
        .limit = 1,
    }) catch return null;

    if (listed.records.len == 0) {
        return null;
    }

    const got = registry.SDK.dispatch(&ctx, record_operations.Get, .{
        .id = listed.records[0].id,
        .purpose = .edit,
    }) catch return null;
    const document = try parsed(visit.arena, got.document);

    return try entry_of(visit.arena, handle, got.record.id, slug, got.record.title, document);
}

/// The previewed record, when this page is its own: a saved one by its slug (as the form
/// renames it), a new one at `new`.
fn own_entry(
    visit: Visit,
    ctx: *sdk.Ctx,
    handle: []const u8,
    slug: []const u8,
) !?PageContext.Entry {
    std.debug.assert(handle.len > 0);
    std.debug.assert(slug.len > 0);

    const fresh = std.mem.eql(u8, visit.record, "new");
    const posted_type = if (visit.form) |form| form.get("type") orelse "" else "";

    if (fresh and !(std.mem.eql(u8, posted_type, handle) and std.mem.eql(u8, slug, "new"))) {
        return null;
    }

    const def = definition_of(ctx, handle) orelse return null;
    var base: Value = .{
        .object = .empty,
    };
    var title: []const u8 = "";
    var saved_slug: ?[]const u8 = null;

    if (!fresh) {
        const got = registry.SDK.dispatch(ctx, record_operations.Get, .{
            .id = visit.record,
            .purpose = .edit,
        }) catch return null;

        if (!std.mem.eql(u8, got.record.type, handle)) {
            return null;
        }

        base = try parsed(visit.arena, got.document);
        title = got.record.title;
        saved_slug = got.record.slug;
    }

    const document = if (visit.form) |form| try overlaid(visit.arena, base, def, form) else base;
    const own_slug = slug_of(def, document) orelse saved_slug orelse "new";

    if (!std.mem.eql(u8, own_slug, slug)) {
        return null;
    }

    const id = if (fresh) "" else visit.record;

    const shown_title = title_of(def, document) orelse title;

    return try entry_of(visit.arena, handle, id, slug, shown_title, document);
}

fn entry_of(
    arena: std.mem.Allocator,
    handle: []const u8,
    id: []const u8,
    slug: []const u8,
    title: []const u8,
    document: Value,
) !PageContext.Entry {
    std.debug.assert(handle.len > 0);
    std.debug.assert(slug.len > 0);

    const fields_value: ?Value = if (document == .object) document else null;
    var entry = try pages.stand_in(arena, handle, fields_value);

    entry.id = id;
    entry.slug = slug;
    entry.title = title;

    return entry;
}

/// Where a record's own page is, inside the project: its app's mount and the route's path for
/// its slug (`new` for a record not given one yet). The record's own app first, else the first
/// app with a page for the type.
pub fn own_path(
    project: *const Project,
    arena: std.mem.Allocator,
    app_name: ?[]const u8,
    handle: []const u8,
    slug: ?[]const u8,
) !?[]const u8 {
    std.debug.assert(handle.len > 0);
    std.debug.assert(slug == null or slug.?.len > 0);

    const found = page_for(project, app_name, handle) orelse return null;
    const mount = found.app.base()[@min(project.admin_path().len, found.app.base().len)..];
    const path = try engine.routes.substitute(arena, found.route.pattern, slug orelse "new");

    return try std.fmt.allocPrint(arena, "{s}{s}", .{ mount, path });
}

pub const Page = struct {
    app: *const App,
    route: *const engine.Route,
};

/// The record's own app first, when it has a page for the type; else the first app that has.
pub fn page_for(project: *const Project, app_name: ?[]const u8, handle: []const u8) ?Page {
    std.debug.assert(handle.len > 0);
    std.debug.assert(project.apps.len <= 1024);

    if (app_name) |name| {
        if (project.find(name)) |app| {
            if (files.route_of(app, handle)) |route| {
                return .{
                    .app = app,
                    .route = route,
                };
            }
        }
    }

    for (project.apps) |*app| {
        if (files.route_of(app, handle)) |route| {
            return .{
                .app = app,
                .route = route,
            };
        }
    }

    return null;
}

fn definition_of(ctx: *sdk.Ctx, handle: []const u8) ?Def {
    std.debug.assert(handle.len > 0);
    std.debug.assert(ctx.caller != .anonymous);

    const got = registry.SDK.dispatch(ctx, types.Get, .{
        .type = handle,
    }) catch return null;

    return got.definition;
}

fn parsed(arena: std.mem.Allocator, text: []const u8) !Value {
    std.debug.assert(text.len > 0);
    std.debug.assert(text.len <= fields.json_bytes_max * 64);

    return std.json.parseFromSliceLeaky(Value, arena, text, .{});
}

/// The form read as the editor saves it, written over `base`: a field posted blank clears.
fn overlaid(arena: std.mem.Allocator, base: Value, def: Def, form: *const admin.Form) !Value {
    std.debug.assert(def.handle.len > 0);
    std.debug.assert(base == .object);

    const text = fields.decode.document_of(arena, def.fields, form) orelse return error.Invalid;
    const posted = try parsed(arena, text);
    var document = try base.object.clone(arena);

    std.debug.assert(posted == .object);

    var iterator = posted.object.iterator();

    while (iterator.next()) |field| {
        if (field.value_ptr.* == .null) {
            _ = document.orderedRemove(field.key_ptr.*);
        } else {
            try document.put(arena, field.key_ptr.*, field.value_ptr.*);
        }
    }

    return .{
        .object = document,
    };
}

fn title_of(def: Def, document: Value) ?[]const u8 {
    std.debug.assert(document == .object);
    std.debug.assert(def.handle.len > 0);

    if (def.title_field.len == 0) {
        return null;
    }

    const value = document.object.get(def.title_field) orelse return null;

    return if (value == .string) value.string else null;
}

fn slug_of(def: Def, document: Value) ?[]const u8 {
    std.debug.assert(document == .object);
    std.debug.assert(def.fields.len <= model.field.fields_max);

    for (def.fields) |field| {
        if (!std.mem.eql(u8, field.kind, "slug")) {
            continue;
        }

        const value = document.object.get(field.name) orelse return null;

        return if (value == .string and value.string.len > 0) value.string else null;
    }

    return null;
}
