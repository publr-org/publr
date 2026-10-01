//! Where a compiled-in plugin shows in the admin: settings pages, listed in the Settings
//! sidebar, an item in the top bar, and actions on the rows of another plugin's page. A
//! settings page is one of the plugin's own routes; the top bar item is a function the
//! admin calls for every signed-in page; a row action is data the page's owner reads.
const std = @import("std");
const route = @import("route.zig");

pub const settings_pages_max: u32 = 8;
pub const row_actions_max: u32 = 8;

pub const SettingsPage = struct {
    label: []const u8,
    /// An icon of the set; a name the plugin's views do not use goes in its `ui/icons.txt`.
    icon: []const u8,
    /// One of the plugin's own `get` routes.
    path: []const u8,
    /// Listed for whoever may call this operation.
    operation: type,
};

/// An item in the menu on each row of a page a plugin owns: the page names its slot and
/// what `kind` and `{name}` mean for its rows, so a plugin building on another adds to its
/// page without either knowing the other's code.
pub const RowAction = struct {
    /// The page, as its owner names it: `orders`.
    slot: []const u8,
    label: []const u8,
    /// Where it goes, a path on the site; `{name}` stands for the row's name.
    path: []const u8,
    /// Only on rows of this kind, as the page's owner names kinds; every row when empty.
    kind: []const u8 = "",
    /// Offered to whoever may call this operation.
    operation: type,
};

/// The row actions a plugin declares.
pub fn row_actions_of(comptime Plugin: type) []const RowAction {
    comptime {
        const name = Plugin.manifest.name;

        if (!@hasDecl(Plugin, "row_actions")) {
            return &.{};
        }

        const actions: []const RowAction = &Plugin.row_actions;

        if (actions.len == 0 or actions.len > row_actions_max) {
            @compileError("plugin " ++ name ++ ": `row_actions` holds 1 to 8 actions");
        }

        for (actions) |action| {
            if (action.slot.len == 0 or action.label.len == 0) {
                @compileError("plugin " ++ name ++ ": a row action needs a slot and a label");
            }

            if (action.path.len == 0 or action.path[0] != '/') {
                @compileError("plugin " ++ name ++ ": row action " ++ action.label ++
                    " goes to a path on the site");
            }
        }

        return actions;
    }
}

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
