//! The tabs plugins add to a Settings page (System settings, Users): each tab's page holds
//! the sections every plugin naming it draws, in plugin order, under the page's own header
//! and tabs.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");

const views = admin.views;
const TabPage = @import("../../sdk/plugin.zig").SettingsTabPage;

/// A tab link, as the pages draw them.
pub const Link = struct {
    tab: []const u8,
    label: []const u8,
    href: []const u8,
};

/// What the open tab puts in its page's header: its primary action, if any.
pub const Action = struct {
    label: []const u8 = "",
    href: []const u8 = "",
};

/// Each plugin tab's page at `<page path>/<tab>`.
pub fn register(router: anytype) void {
    std.debug.assert(tabs.len <= 64);

    inline for (tabs) |tab| {
        const Shown = Page(tab.page, tab.tab);

        router.get(comptime tab.page.path() ++ "/" ++ tab.tab, &Shown.show);
    }
}

/// Every tab a plugin adds, once each per page, in the order first declared.
pub const tabs = distinct_tabs();

fn distinct_tabs() []const registry_tab {
    comptime {
        std.debug.assert(registry.settings_tabs.len <= 64);

        var found: []const registry_tab = &.{};

        for (registry.settings_tabs) |owned| {
            var seen = false;

            for (found) |known| {
                seen = seen or (known.page == owned.tab.page and
                    std.mem.eql(u8, known.tab, owned.tab.tab));
            }

            if (!seen) {
                found = found ++ &[_]registry_tab{.{
                    .page = owned.tab.page,
                    .tab = owned.tab.tab,
                    .label = owned.tab.tab_label,
                }};
            }
        }

        return found;
    }
}

const registry_tab = struct {
    page: TabPage,
    tab: []const u8,
    label: []const u8,
};

/// The links to the plugin tabs of `page` the viewer may see.
pub fn links(session: *admin.Session, page: TabPage) admin.Error![]const Link {
    std.debug.assert(session.signed_in());
    std.debug.assert(tabs.len <= 64);

    var shown: std.ArrayList(Link) = .empty;

    inline for (tabs) |tab| {
        if (tab.page == page and may_see(session, tab.page, tab.tab)) {
            shown.append(session.arena, .{
                .tab = tab.tab,
                .label = try session.declared(tab.label),
                .href = comptime tab.page.path() ++ "/" ++ tab.tab,
            }) catch return error.OutOfMemory;
        }
    }

    return shown.items;
}

fn may_see(session: *admin.Session, comptime page: TabPage, comptime tab: []const u8) bool {
    std.debug.assert(tab.len > 0);
    std.debug.assert(session.signed_in());

    inline for (registry.settings_tabs) |owned| {
        if (comptime ours(owned.tab, page, tab)) {
            if (registry.SDK.may(&session.ctx, owned.tab.operation)) {
                return true;
            }
        }
    }

    return false;
}

fn ours(comptime declared: anytype, comptime page: TabPage, comptime tab: []const u8) bool {
    return declared.page == page and std.mem.eql(u8, declared.tab, tab);
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
        const mine = comptime ours(owned.tab, .system, tab);

        if (mine and registry.SDK.may(&session.ctx, owned.tab.operation)) {
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

/// The page of the plugin tab `tab` of `page`: its sections, drawn by their plugins.
pub fn Page(comptime page: TabPage, comptime tab: []const u8) type {
    return struct {
        pub fn show(
            request: *admin.Request,
            response: *admin.Response,
            ctx: *admin.Context,
        ) admin.Error!void {
            std.debug.assert(request.method() == .get or request.method() == .head);
            std.debug.assert(ctx.user_data != null);

            var session = try admin.require(request, response, ctx) orelse return;

            if (!may_see(&session, page, tab)) {
                return admin.missing(request, response, ctx);
            }

            var sections: std.ArrayList(admin.render.Node) = .empty;
            var action: Action = .{};

            inline for (registry.settings_tabs) |owned| {
                const mine = comptime ours(owned.tab, page, tab);

                if (mine and registry.SDK.may(&session.ctx, owned.tab.operation)) {
                    const node = try owned.tab.view.draw(&session);

                    sections.append(session.arena, node) catch return error.OutOfMemory;

                    if (action.label.len == 0 and owned.tab.action_label.len > 0) {
                        action = .{
                            .label = try session.declared(owned.tab.action_label),
                            .href = owned.tab.action_href,
                        };
                    }
                }
            }

            const body = try admin.render.all(session.arena, sections.items);

            switch (page) {
                .system => try @import("settings.zig").render_plugin_tab(&session, tab, body),
                .users => try @import("users.zig").render_plugin_tab(&session, tab, body, action),
            }
        }
    };
}
