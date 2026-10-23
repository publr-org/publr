//! Where a type lives, which apps it is shared with and who reads it, on the type's
//! settings form: drawn from the definition and the project's apps, read back from the post.
const std = @import("std");
const admin = @import("../admin.zig");
const model = @import("../../model.zig");
const app_scope = @import("app_scope.zig");
const values_of = @import("type_fields/settings.zig").values_of;
const registry = @import("../../server/registry.zig");

const Error = admin.Error;
const Form = admin.Form;
const Session = admin.Session;
const Def = model.content_type.Def;
const Shared = model.content_type.Shared;
const AppItem = admin.views.TypeForm.AppsItem;
const ShareItem = admin.views.TypeForm.SharesItem;
const RoleItem = admin.views.TypeForm.RolesItem;

pub const Props = struct {
    has_apps: bool,
    is_global: bool,
    home: []const u8,
    apps: []const AppItem,
    share_all: bool,
    shares: []const ShareItem,
    /// The site's roles, those the type keeps to ticked.
    roles: []const RoleItem,
};

/// A new type lives in the app the admin is narrowed to, else it is Global.
pub fn new_def(session: *const Session, def: Def) Def {
    std.debug.assert(def.handle.len == 0);
    std.debug.assert(def.app.len == 0);

    var placed = def;

    placed.app = app_scope.of(session).app_name() orelse "";

    return placed;
}

pub fn props_of(session: *Session, def: Def) Error!Props {
    std.debug.assert(session.project.apps.len <= 1024);
    std.debug.assert(def.app.len <= 64);

    const arena = session.arena;
    const project_apps = session.project.apps;
    const shared = model.content_type.shared_of(def);
    const apps = try arena.alloc(AppItem, project_apps.len);
    var shares: std.ArrayList(ShareItem) = .empty;

    for (project_apps, apps) |*app, *item| {
        const name = app.spec.name;
        const home = std.mem.eql(u8, name, def.app);

        item.* = .{
            .value = name,
            .label = app.spec.label,
            .selected = home,
        };

        try shares.append(arena, .{
            .value = name,
            .label = app.spec.label,
            .checked = !home and listed(shared.apps, name),
        });
    }

    return .{
        .has_apps = project_apps.len > 0,
        .is_global = def.app.len == 0,
        .home = def.app,
        .apps = apps,
        .share_all = shared.all,
        .shares = shares.items,
        .roles = try roles_of(session, def),
    };
}

fn roles_of(session: *Session, def: Def) Error![]const RoleItem {
    std.debug.assert(def.roles.len <= model.role.roles_max);

    const role_operations = @import("../../operations/role.zig");
    // Someone who may not list the roles sees none to tick; the type keeps its own.
    const found = registry.SDK.dispatch(&session.ctx, role_operations.List, .{}) catch {
        return &.{};
    };
    var items: std.ArrayList(RoleItem) = .empty;

    for (found.roles) |each| {
        try items.append(session.arena, .{
            .value = each.name,
            .label = try session.declared(each.label),
            .checked = listed(def.roles, each.name),
        });
    }

    return items.items;
}

/// The post over `base`: the app it lives in, who it is shared with, Public or Private
/// and a Private one's roles.
/// A form without the app questions (a project with no apps) keeps where it lives.
pub fn read(arena: std.mem.Allocator, form: *const Form, base: Def) Error!Def {
    std.debug.assert(form.len <= admin.form_pairs_max);
    std.debug.assert(base.handle.len <= model.content_type.handle_len_max);

    var def = base;

    if (form.get("access")) |access| {
        def.public = std.mem.eql(u8, access, "public");
        def.roles = if (def.public) &.{} else try values_of(arena, form, "roles");
    }

    if (form.get("untranslated")) |chosen| {
        def.variant_fallback = !std.mem.eql(u8, chosen, "omit");
    }

    const share = form.text("share") orelse return def;

    def.app = form.text("app") orelse "";

    const apps = try values_of(arena, form, "shared");
    var others: std.ArrayList([]const u8) = .empty;

    for (apps) |name| {
        if (!std.mem.eql(u8, name, def.app)) {
            try others.append(arena, name);
        }
    }

    const shared: Shared = .{
        .all = std.mem.eql(u8, share, "all"),
        .apps = others.items,
    };
    const default = model.content_type.shared_of(.{
        .handle = def.handle,
        .name = def.name,
        .app = def.app,
        .fields = &.{},
    });
    const is_default = shared.all == default.all and shared.apps.len == 0;

    def.shared = if (is_default) null else shared;

    return def;
}

fn listed(names: []const []const u8, name: []const u8) bool {
    std.debug.assert(names.len <= model.content_type.shared_apps_max);
    std.debug.assert(names.len <= model.role.roles_max);
    std.debug.assert(name.len > 0);

    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) {
            return true;
        }
    }

    return false;
}
