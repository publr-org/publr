//! Where a plugin shows in the admin. Any plugin: its own pages, shown in the plugin frame
//! and listed in the Settings sidebar, sections, panels, an item in the top bar, and actions
//! on the rows of another plugin's page. Compiled in only, for now: settings pages, listed
//! in the Settings sidebar, and settings tabs. A settings page is one of the plugin's own
//! routes; the top bar item is a function the admin calls for every signed-in page; a row
//! action is data the page's owner reads.
const std = @import("std");
const plugin_define = @import("define.zig");
const route = @import("route.zig");

pub const settings_pages_max: u32 = 8;
pub const row_actions_max: u32 = 8;
pub const pages_max: u32 = 8;
pub const page_path_len_max: u32 = 48;

/// A page of the plugin's own, at `/admin/plugin/<plugin>/<path>`, listed in the Settings
/// sidebar and shown in the plugin frame: a sandboxed iframe with an opaque origin that
/// talks to the admin only by `postMessage`, so what it draws never reaches the admin.
/// `operation` draws it: a read of the plugin's own taking `query` (the address's query
/// string) and `base` (the path the project is served under), and answering `html`: a
/// page drawn by the admin's layouts (`publr.admin.chrome.in_plugin_frame`), or any markup
/// and script the plugin likes. The same in both modes.
pub const Page = struct {
    /// Lowercase letters, digits and dashes.
    path: []const u8,
    label: []const u8,
    /// An icon of the set; a name the admin does not carry shows the plugin icon.
    icon: []const u8,
    /// Listed and drawn for whoever may call it. Null for a page by declaration (`form`).
    operation: ?type = null,
    /// A form the admin draws itself, with no markup of the plugin's: the fields of
    /// `save`'s input, filled from what `read` answers. It works in the sandbox as it is.
    form: ?Form = null,
    /// Also in the top bar, for whoever may see the page: `.{ .count = Unseen }`, a read of
    /// the plugin's own with no input answering `count`, shown beside the label.
    top_bar: ?TopBar = null,
    /// `.none`: no entry in the menu; the page still opens at its address, for links of the
    /// plugin's own.
    menu: ?enum { none } = null,

    /// The operation that decides who sees the page: the drawing read, or the form's.
    pub fn gate(comptime page: Page) type {
        comptime {
            return page.operation orelse page.form.?.read;
        }
    }
};

pub const TopBar = struct {
    count: ?type = null,
};

/// An entry a plugin adds to the top bar: data only, the
/// admin's own components draw it, so it looks like the admin's and cannot pass for
/// anything else. The same in both modes.
pub const Item = struct {
    label: []const u8,
    /// An icon of the set; a name the admin does not carry shows the plugin icon.
    icon: []const u8,
    /// One of the plugin's own pages, by its `path`.
    page: []const u8,
    /// Shown to whoever may call it.
    operation: type,
    /// A read of the plugin's own with no input, answering `count`: shown beside the label.
    count: ?type = null,
};

pub const items_max: u32 = 4;

/// The plugin's top bar entries: its pages that say `.top_bar`, checked.
pub fn items_of(comptime Plugin: type) []const Item {
    comptime {
        const name = Plugin.manifest.name;
        var items: []const Item = &.{};

        std.debug.assert(name.len > 0);

        if (!plugin_define.has(Plugin, "pages")) {
            return &.{};
        }

        for (plugin_define.get(Plugin, "pages")) |page| {
            const shown = page.top_bar orelse continue;

            if (shown.count) |Count| {
                if (Count.kind != .read or !@hasField(Count.Out, "count")) {
                    @compileError("plugin " ++ name ++ ": page " ++ page.path ++
                        " counts with a read answering `count`");
                }
            }

            items = items ++ &[_]Item{.{
                .label = page.label,
                .icon = page.icon,
                .page = page.path,
                .operation = page.gate(),
                .count = shown.count,
            }};
        }

        if (items.len > items_max) {
            @compileError("plugin " ++ name ++ ": at most 4 pages are in the top bar");
        }

        const done = items;

        return done;
    }
}

/// A box a plugin adds to a content type's edit form, any plugin's type or the core's: its
/// read draws it in the plugin frame, told only which record it is on (`In.record`, an id)
/// and the admin's base path, answering `publr.views.render(ctx, in.base, View, props)` as
/// `html`, a view of its own on the `PanelPage` layout; markup of its own is refused. The
/// plugin reads whatever else it needs itself, as it may. Shown to whoever may call the
/// read, on records of that type, when the type is there.
pub const Panel = struct {
    /// The content type's handle.
    type: []const u8,
    label: []const u8,
    operation: type,
};

pub const panels_max: u32 = 8;

/// The plugin's panels, each drawn by a read taking `record` and answering `html`.
pub fn panels_of(comptime Plugin: type) []const Panel {
    comptime {
        const name = Plugin.manifest.name;

        if (!plugin_define.has(Plugin, "panels")) {
            return &.{};
        }

        const panels: []const Panel = plugin_define.get(Plugin, "panels");

        if (panels.len == 0 or panels.len > panels_max) {
            @compileError("plugin " ++ name ++ ": `panels` holds 1 to 8");
        }

        for (panels) |panel| {
            const Operation = panel.operation;
            const draws = Operation.kind == .read and @hasField(Operation.In, "record") and
                @hasField(Operation.Out, "html");

            if (panel.type.len == 0 or panel.label.len == 0 or !draws) {
                @compileError("plugin " ++ name ++ ": panel " ++ panel.label ++ " names a " ++
                    "type, a label, and a read taking `record` and answering `html`");
            }
        }

        return panels;
    }
}

pub const Form = struct {
    /// A read of the plugin's own, no input, answering the values.
    read: type,
    /// A write of the plugin's own taking every field.
    save: type,
};

pub const SettingsPage = struct {
    label: []const u8,
    /// An icon of the set; a name the plugin's views do not use goes in its `ui/icons.txt`.
    icon: []const u8,
    /// One of the plugin's own `get` routes.
    path: []const u8,
    /// Listed for whoever may call this operation.
    operation: type,
};

/// The Settings pages plugins add tabs to: System settings
/// (`/admin/settings/system/<tab>`) and Users (`/admin/settings/users/<tab>`).
pub const SettingsTabPage = enum {
    system,
    users,

    pub fn path(page: SettingsTabPage) []const u8 {
        return switch (page) {
            .system => "/admin/settings/system",
            .users => "/admin/settings/users",
        };
    }
};

/// A section a plugin adds to a tab of a Settings page, System settings unless `page` says
/// Users. Plugins naming the same tab share it, their sections in plugin order; the tab
/// shows while any plugin adds to it, and a page with none shows no tabs. Compiled in only:
/// `view.draw(session)` draws the section with the admin's own components, and the plugin's
/// routes take what it posts.
pub const SettingsTab = struct {
    page: SettingsTabPage = .system,
    /// Lowercase letters and dashes: `localization`.
    tab: []const u8,
    /// The tab's name: `Localization`. Plugins sharing a tab give the same one.
    tab_label: []const u8,
    /// A struct with `pub fn draw(session: *publr.admin.Session) publr.admin.Error!Node`.
    view: type,
    /// Shown to whoever may call this operation.
    operation: type,
    /// The page's primary action while the tab is open (`Add role`), a path in the admin;
    /// empty for none.
    action_label: []const u8 = "",
    action_href: []const u8 = "",
};

pub const settings_tabs_max: u32 = 4;
/// The tabs System settings has of its own: a plugin's tab is named otherwise.
pub const own_settings_tabs = [_][]const u8{ "general", "currencies", "activity", "errors" };
/// What Users' own addresses take after `/admin/settings/users/`.
pub const own_users_paths = [_][]const u8{ "users", "new", "create" };

/// The settings tab sections a plugin declares, checked.
pub fn settings_tabs_of(comptime Plugin: type) []const SettingsTab {
    comptime {
        const name = Plugin.manifest.name;

        std.debug.assert(name.len > 0);

        if (!plugin_define.has(Plugin, "settings_tabs")) {
            return &.{};
        }

        const tabs: []const SettingsTab = plugin_define.get(Plugin, "settings_tabs");

        if (tabs.len == 0 or tabs.len > settings_tabs_max) {
            @compileError("plugin " ++ name ++ ": `settings_tabs` holds 1 to 4 sections");
        }

        for (tabs) |tab| {
            if (!valid_tab(tab.tab) or tab.tab_label.len == 0) {
                @compileError("plugin " ++ name ++ ": a settings tab is named in lowercase " ++
                    "letters and dashes, not one of its page's own, and has a label");
            }

            if (tab.page == .users and taken_by_users(tab.tab)) {
                @compileError("plugin " ++ name ++ ": tab " ++ tab.tab ++ " is a Users path");
            }

            if (!@hasDecl(tab.view, "draw")) {
                @compileError("plugin " ++ name ++ ": a settings tab's view has `draw`");
            }
        }

        return tabs;
    }
}

fn valid_tab(comptime tab: []const u8) bool {
    comptime {
        std.debug.assert(own_settings_tabs.len > 0);

        if (tab.len == 0 or tab.len > page_path_len_max) {
            return false;
        }

        for (own_settings_tabs) |own| {
            if (std.mem.eql(u8, own, tab)) {
                return false;
            }
        }

        for (tab) |char| {
            if (!std.ascii.isLower(char) and char != '-') {
                return false;
            }
        }

        return true;
    }
}

fn taken_by_users(comptime tab: []const u8) bool {
    comptime {
        std.debug.assert(tab.len > 0);

        for (own_users_paths) |own| {
            if (std.mem.eql(u8, own, tab)) {
                return true;
            }
        }

        return false;
    }
}

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

        if (!plugin_define.has(Plugin, "row_actions")) {
            return &.{};
        }

        const actions: []const RowAction = plugin_define.get(Plugin, "row_actions");

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

/// The pages a plugin declares, each drawn by a read of its own.
pub fn pages_of(comptime Plugin: type) []const Page {
    comptime {
        const name = Plugin.manifest.name;

        if (!plugin_define.has(Plugin, "pages")) {
            return &.{};
        }

        const pages: []const Page = plugin_define.get(Plugin, "pages");

        if (pages.len == 0 or pages.len > pages_max) {
            @compileError("plugin " ++ name ++ ": `pages` holds 1 to 8 pages");
        }

        for (pages, 0..) |page, index| {
            if (page.label.len == 0 or page.icon.len == 0) {
                @compileError("plugin " ++ name ++ ": a page needs a label and an icon");
            }

            if (!is_page_path(page.path)) {
                @compileError("plugin " ++ name ++ ": page path \"" ++ page.path ++
                    "\" is lowercase letters, digits and dashes, up to 48");
            }

            for (pages[index + 1 ..]) |other| {
                if (std.mem.eql(u8, page.path, other.path)) {
                    @compileError("plugin " ++ name ++ ": two pages at " ++ page.path);
                }
            }

            if ((page.operation == null) == (page.form == null)) {
                @compileError("plugin " ++ name ++ ": page " ++ page.path ++
                    " is drawn by an `operation` or declared as a `form`, one of them");
            }

            if (page.operation) |Operation| {
                assert_draws(name, Operation);
            } else {
                assert_form(name, page.form.?);
            }
        }

        return pages;
    }
}

/// Whether `path` names a page: lowercase letters, digits and dashes.
pub fn is_page_path(path: []const u8) bool {
    std.debug.assert(page_path_len_max > 0);

    if (path.len == 0 or path.len > page_path_len_max) {
        return false;
    }

    for (path) |char| {
        const allowed = (char >= 'a' and char <= 'z') or (char >= '0' and char <= '9') or
            char == '-';

        if (!allowed) {
            return false;
        }
    }

    return true;
}

fn assert_form(comptime plugin: []const u8, comptime form: Form) void {
    comptime {
        const label = "plugin " ++ plugin ++ ": form ";

        if (form.read.kind != .read or @typeInfo(form.read.In).@"struct".fields.len != 0) {
            @compileError(label ++ form.read.name ++ " is a read with no input");
        }

        if (form.save.kind != .write) {
            @compileError(label ++ form.save.name ++ " is a write");
        }
    }
}

fn assert_draws(comptime plugin: []const u8, comptime Operation: type) void {
    comptime {
        const label = "plugin " ++ plugin ++ ": page operation " ++ Operation.name;

        if (Operation.kind != .read) {
            @compileError(label ++ " is a read");
        }

        for ([_][]const u8{ "query", "base" }) |field| {
            if (!@hasField(Operation.In, field) or @FieldType(Operation.In, field) != []const u8) {
                @compileError(label ++ " takes `query` and `base`, both `[]const u8`");
            }
        }

        if (!@hasField(Operation.Out, "html") or @FieldType(Operation.Out, "html") != []const u8) {
            @compileError(label ++ " answers `html: []const u8`");
        }
    }
}

test "a page path is lowercase letters, digits and dashes" {
    try std.testing.expect(is_page_path("notes"));
    try std.testing.expect(is_page_path("by-week-2"));
    try std.testing.expect(!is_page_path(""));
    try std.testing.expect(!is_page_path("Notes"));
    try std.testing.expect(!is_page_path("a/b"));
    try std.testing.expect(!is_page_path("a?b"));
}

/// The settings pages a plugin declares, each one of its own `get` routes.
pub fn settings_pages_of(
    comptime Plugin: type,
    comptime routes: []const route.Declared,
) []const SettingsPage {
    comptime {
        const name = Plugin.manifest.name;

        std.debug.assert(name.len > 0);

        if (!plugin_define.has(Plugin, "settings_pages")) {
            return &.{};
        }

        const pages: []const SettingsPage = plugin_define.get(Plugin, "settings_pages");

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
