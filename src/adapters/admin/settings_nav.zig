//! The Settings sidebar: the system's settings, the users and the plugins first, then the
//! pages compiled-in plugins add, then every settings definition as a value-editing
//! destination. `current` is the fixed page, the handle shown, or a plugin page's path.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const types = @import("../../operations/content_type.zig");

pub fn node(session: *admin.Session, current: []const u8) admin.Error!admin.render.Node {
    std.debug.assert(session.signed_in());
    const listed = registry.SDK.dispatch(
        &session.ctx,
        types.List,
        .{},
    ) catch return error.OutOfMemory;
    var items: std.ArrayList(admin.views.SettingsNav.SectionsItem) = .empty;

    for (listed.types) |summary| {
        if (summary.kind != .settings) continue;
        try items.append(session.arena, .{
            .label = summary.name,
            .href = try std.fmt.allocPrint(session.arena, "/admin/settings/{s}", .{summary.handle}),
            .active = std.mem.eql(u8, current, summary.handle),
        });
    }

    return admin.render.view(session.arena, admin.views.SettingsNav, .{
        .system_active = std.mem.eql(u8, current, "system"),
        .users_active = std.mem.eql(u8, current, "users"),
        .plugins_active = std.mem.eql(u8, current, "plugins"),
        .pages = try pages_of(session, current),
        .sections = items.items,
    });
}

const Page = admin.views.SettingsNav.PagesItem;

/// Each plugin's pages, for whoever may call what the page is for.
fn pages_of(session: *admin.Session, current: []const u8) admin.Error![]const Page {
    std.debug.assert(session.signed_in());

    var pages: std.ArrayList(Page) = .empty;

    inline for (registry.settings_pages) |page| {
        if (registry.SDK.may(&session.ctx, page.operation)) {
            try pages.append(session.arena, .{
                .label = page.label,
                .href = page.path,
                .icon = comptime icon_of(page.icon),
                .active = std.mem.eql(u8, current, page.path),
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
