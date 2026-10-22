//! The tabs plugins add to Users: each tab's page holds the sections every plugin naming it
//! draws, in plugin order, under the page's own header and tabs.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");

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

const users_path = "/admin/settings/users";

/// Each plugin tab's page at `/admin/settings/users/<tab>`.
pub fn register(router: anytype) void {
    std.debug.assert(tabs.len <= 64);

    inline for (tabs) |tab| {
        const Shown = Page(tab.tab);

        router.get(users_path ++ "/" ++ tab.tab, &Shown.show);
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

/// The links to the plugin tabs of Users the viewer may see.
pub fn links(session: *admin.Session) admin.Error![]const Link {
    std.debug.assert(session.signed_in());
    std.debug.assert(tabs.len <= 64);

    var shown: std.ArrayList(Link) = .empty;

    inline for (tabs) |tab| {
        if (may_see(session, tab.tab)) {
            shown.append(session.arena, .{
                .tab = tab.tab,
                .label = try session.declared(tab.label),
                .href = users_path ++ "/" ++ tab.tab,
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

/// The page of the plugin tab `tab` of Users: its sections, drawn by their plugins.
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
            var action: Action = .{};

            inline for (registry.settings_tabs) |owned| {
                const mine = comptime std.mem.eql(u8, owned.tab.tab, tab);

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

            try @import("users.zig").render_plugin_tab(&session, tab, body, action);
        }
    };
}
