//! The tabs plugins add to System settings: each tab's page holds the sections every plugin
//! naming it draws, in plugin order, under System settings' own header and tabs.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");

const views = admin.views;
const page_path = "/admin/settings/system";
const Tab = views.SettingsSystem.Plugin_tabsItem;

/// Each plugin tab's page at `/admin/settings/system/<tab>`.
pub fn register(router: anytype) void {
    std.debug.assert(tabs.len <= 64);

    inline for (tabs) |tab| {
        const Shown = Page(tab.tab);

        router.get("/admin/settings/system/" ++ tab.tab, &Shown.show);
    }
}

/// Every tab a plugin adds, once each, in the order first declared.
pub const tabs = distinct_tabs();

fn distinct_tabs() []const registry_tab {
    comptime {
        std.debug.assert(registry.settings_tabs.len <= 64);

        var found: []const registry_tab = &.{};

        for (registry.settings_tabs) |owned| {
            var seen = false;

            for (found) |known| {
                seen = seen or std.mem.eql(u8, known.tab, owned.tab.tab);
            }

            if (!seen) {
                found = found ++ &[_]registry_tab{.{
                    .tab = owned.tab.tab,
                    .label = owned.tab.tab_label,
                }};
            }
        }

        return found;
    }
}

const registry_tab = struct {
    tab: []const u8,
    label: []const u8,
};

/// The links to the plugin tabs the viewer may see.
pub fn links(session: *admin.Session) admin.Error![]const Tab {
    std.debug.assert(session.signed_in());
    std.debug.assert(tabs.len <= 64);

    var shown: std.ArrayList(Tab) = .empty;

    inline for (tabs) |tab| {
        if (may_see(session, tab.tab)) {
            shown.append(session.arena, .{
                .tab = tab.tab,
                .label = try session.declared(tab.label),
                .href = page_path ++ "/" ++ tab.tab,
            }) catch return error.OutOfMemory;
        }
    }

    return shown.items;
}

fn may_see(session: *admin.Session, comptime tab: []const u8) bool {
    std.debug.assert(tab.len > 0);
    std.debug.assert(session.signed_in());

    inline for (registry.settings_tabs) |owned| {
        if (comptime std.mem.eql(u8, owned.tab.tab, tab)) {
            if (registry.SDK.may(&session.ctx, owned.tab.operation)) {
                return true;
            }
        }
    }

    return false;
}

/// The tab drawn again after `plugin`'s save was refused: its section is `section` (what was
/// posted, and why it was refused), the others as they are.
pub fn show_refused(
    session: *admin.Session,
    comptime tab: []const u8,
    plugin: []const u8,
    section: admin.render.Node,
) admin.Error!void {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(session.signed_in());

    var sections: std.ArrayList(admin.render.Node) = .empty;

    inline for (registry.settings_tabs) |owned| {
        const ours = comptime std.mem.eql(u8, owned.tab.tab, tab);

        if (ours and registry.SDK.may(&session.ctx, owned.tab.operation)) {
            const node = if (std.mem.eql(u8, owned.plugin, plugin))
                section
            else
                try owned.tab.view.draw(session);

            sections.append(session.arena, node) catch return error.OutOfMemory;
        }
    }

    const body = try admin.render.all(session.arena, sections.items);

    try @import("settings.zig").render_plugin_tab(session, tab, body);
}

/// The page of the plugin tab `tab`: its sections, drawn by their plugins.
pub fn Page(comptime tab: []const u8) type {
    return struct {
        pub fn show(
            request: *admin.Request,
            response: *admin.Response,
            ctx: *admin.Context,
        ) admin.Error!void {
            std.debug.assert(request.method() == .get or request.method() == .head);
            std.debug.assert(ctx.user_data != null);

            var session = try admin.require(request, response, ctx) orelse return;

            if (!may_see(&session, tab)) {
                return admin.missing(request, response, ctx);
            }

            var sections: std.ArrayList(admin.render.Node) = .empty;

            inline for (registry.settings_tabs) |owned| {
                const ours = comptime std.mem.eql(u8, owned.tab.tab, tab);

                if (ours and registry.SDK.may(&session.ctx, owned.tab.operation)) {
                    const node = try owned.tab.view.draw(&session);

                    sections.append(session.arena, node) catch return error.OutOfMemory;
                }
            }

            const body = try admin.render.all(session.arena, sections.items);

            try @import("settings.zig").render_plugin_tab(&session, tab, body);
        }
    };
}
