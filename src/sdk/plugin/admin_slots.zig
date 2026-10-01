//! Where a compiled-in plugin shows in the admin: settings pages, listed in the Settings
//! sidebar, and an item in the top bar. A settings page is one of the plugin's own routes;
//! the top bar item is a function the admin calls for every signed-in page.
const std = @import("std");
const route = @import("route.zig");

pub const settings_pages_max: u32 = 8;

pub const SettingsPage = struct {
    label: []const u8,
    /// An icon of the set; a name the plugin's views do not use goes in its `ui/icons.txt`.
    icon: []const u8,
    /// One of the plugin's own `get` routes.
    path: []const u8,
    /// Listed for whoever may call this operation.
    operation: type,
};

/// The settings pages a plugin declares, each one of its own `get` routes.
pub fn settings_pages_of(
    comptime Plugin: type,
    comptime routes: []const route.Declared,
) []const SettingsPage {
    comptime {
        const name = Plugin.manifest.name;

        std.debug.assert(name.len > 0);

        if (!@hasDecl(Plugin, "settings_pages")) {
            return &.{};
        }

        const pages: []const SettingsPage = &Plugin.settings_pages;

        if (pages.len == 0 or pages.len > settings_pages_max) {
            @compileError("plugin " ++ name ++ ": `settings_pages` holds 1 to 8 pages");
        }

        for (pages) |page| {
            if (page.label.len == 0 or page.icon.len == 0) {
                @compileError("plugin " ++ name ++ ": a settings page needs a label and an icon");
            }

            if (!declares_get(routes, page.path)) {
                @compileError("plugin " ++ name ++ ": settings page " ++ page.path ++
                    " is not one of its `get` routes");
            }
        }

        return pages;
    }
}

fn declares_get(comptime routes: []const route.Declared, comptime path: []const u8) bool {
    comptime {
        std.debug.assert(path.len > 0);

        for (routes) |declared| {
            if (declared.route.method == .get and std.mem.eql(u8, declared.route.path, path)) {
                return true;
            }
        }

        return false;
    }
}
