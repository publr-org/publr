//! The Settings sidebar: the system's settings, the users and the plugins first, then the
//! pages compiled-in plugins add, then every settings definition as a value-editing
//! destination. The entry the address is under is lit.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const types = @import("../../operations/content_type.zig");
const chrome = @import("chrome.zig");

/// The addresses Structure stands for: the hub and every kind of definition under it.
const structure_paths = [_][]const u8{
    "/admin/structure",
    "/admin/types",
    "/admin/terms",
    "/admin/components",
    "/admin/custom-fields",
};

pub fn node(session: *admin.Session, path: []const u8) admin.Error!admin.render.Node {
    std.debug.assert(session.signed_in());
    std.debug.assert(path.len > 0);

    const listed = registry.SDK.dispatch(
        &session.ctx,
        types.List,
        .{},
    ) catch return error.OutOfMemory;
    var items: std.ArrayList(admin.views.SettingsNav.SectionsItem) = .empty;

    for (listed.types) |summary| {
        if (summary.kind != .settings) continue;

        const href = try std.fmt.allocPrint(session.arena, "/admin/settings/{s}", .{
            summary.handle,
        });

        try items.append(session.arena, .{
            .label = summary.name,
            .href = href,
            .active = chrome.under(path, href),
        });
    }

    return admin.render.view(session.arena, admin.views.SettingsNav, .{
        .system_active = chrome.under(path, "/admin/settings/system"),
        .users_active = chrome.under(path, "/admin/settings/users"),
        .can_structure = registry.SDK.may(&session.ctx, types.Create),
        .structure_active = in_structure(path),
        .plugins_active = chrome.under(path, "/admin/settings/plugins"),
        .pages = try pages_of(session, path),
        .sections = items.items,
    });
}

fn in_structure(path: []const u8) bool {
    std.debug.assert(path.len > 0);
    std.debug.assert(structure_paths.len > 0);

    for (structure_paths) |prefix| {
        if (chrome.under(path, prefix)) {
            return true;
        }
    }

    return false;
}

const Page = admin.views.SettingsNav.PagesItem;

/// Each plugin's pages, for whoever may call what the page is for.
fn pages_of(session: *admin.Session, path: []const u8) admin.Error![]const Page {
    std.debug.assert(session.signed_in());

    var pages: std.ArrayList(Page) = .empty;

    inline for (registry.settings_pages) |page| {
        if (registry.SDK.may(&session.ctx, page.operation)) {
            try pages.append(session.arena, .{
                .label = page.label,
                .href = page.path,
                .icon = comptime icon_of(page.icon),
                .active = chrome.under(path, page.path),
            });
        }
    }

    return pages.items;
}

fn icon_of(comptime name: []const u8) @FieldType(Page, "icon") {
    comptime {
        return std.meta.stringToEnum(@FieldType(Page, "icon"), name) orelse
            @compileError("settings page icon " ++ name ++ " is not in the icon set");
    }
}
