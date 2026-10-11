//! Where a plugin shows in the admin. Any plugin: its own pages, shown in the plugin frame
//! and listed in the Settings sidebar. Compiled in only, for now: settings pages, listed in
//! the Settings sidebar, an item in the top bar, and actions on the rows of another
//! plugin's page. A settings page is one of the plugin's own routes; the top bar item is a
//! function the admin calls for every signed-in page; a row action is data the page's owner
//! reads.
const std = @import("std");
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

    /// The operation that decides who sees the page: the drawing read, or the form's.
    pub fn gate(comptime page: Page) type {
        comptime {
            return page.operation orelse page.form.?.read;
        }
    }
};

/// An entry a plugin adds to the top bar: data only, the
/// admin's own components draw it, so it looks like the admin's and cannot pass for
/// anything else. The same in both modes.
pub const Item = struct {
    label: []const u8,
    /// An icon of the set; a name the admin does not carry shows the plugin icon.
    icon: []const u8,
    /// One of the plugin's own pages, by its `path`. Or `href`.
    page: []const u8 = "",
    /// An address in the admin (`/admin/...`), when it leads elsewhere than the plugin's page.
    href: []const u8 = "",
    /// Shown to whoever may call it.
    operation: type,
    /// A read of the plugin's own with no input, answering `count`: shown beside the label.
    count: ?type = null,
};

pub const items_max: u32 = 4;

/// The entries a plugin adds to `list` (`top_bar`), checked.
pub fn items_of(comptime Plugin: type, comptime list: []const u8) []const Item {
    comptime {
        const name = Plugin.manifest.name;

        // The rail is the person's: a plugin's pages and sections are pinned there by them.
        if (@hasDecl(Plugin, "rail")) {
            @compileError("plugin " ++ name ++ ": the rail is the person's, no plugin adds " ++
                "to it; declare `pages` or `sections`, and people pin them to their rail");
        }

        if (!@hasDecl(Plugin, list)) {
            return &.{};
        }

        const items: []const Item = &@field(Plugin, list);

        if (items.len == 0 or items.len > items_max) {
            @compileError("plugin " ++ name ++ ": `" ++ list ++ "` holds 1 to 4 entries");
        }

        for (items) |item| {
            const leads = (item.page.len > 0) != (item.href.len > 0);

            if (item.label.len == 0 or item.icon.len == 0 or !leads) {
                @compileError("plugin " ++ name ++ ": a `" ++ list ++ "` entry needs a label, " ++
                    "an icon, and a `page` or an `href`, one of them");
            }

            if (item.href.len > 0 and !std.mem.startsWith(u8, item.href, "/admin/")) {
                @compileError("plugin " ++ name ++ ": entry " ++ item.label ++
                    " leads to an address in the admin, `/admin/...`");
            }

            if (item.count) |Count| {
                if (Count.kind != .read or !@hasField(Count.Out, "count")) {
                    @compileError("plugin " ++ name ++ ": entry " ++ item.label ++
                        " counts with a read answering `count`");
                }
            }
        }

        return items;
    }
}

/// A part of the admin of its own, listed in the Content sidebar and pinned to the rail by
/// whoever wants it there: some of the plugin's content types, listed and edited as the
/// admin's content is. Data, the same in both modes.
pub const Section = struct {
    label: []const u8,
    icon: []const u8,
    types: []const SectionType,
};

pub const SectionType = struct {
    /// One of the plugin's own record types, by handle.
    handle: []const u8,
    /// Fields shown in its list after the title, by name: of the kinds a cell can show.
    columns: []const []const u8 = &.{},
};

pub const section_types_max: u32 = 8;
pub const columns_max: u32 = 4;

/// The kinds a list cell shows as text.
pub const column_kinds = [_][]const u8{
    "string",  "text",   "email",   "url",      "slug",  "select",
    "integer", "number", "boolean", "datetime", "money", "color",
};

pub fn column_kind(kind: []const u8) bool {
    std.debug.assert(column_kinds.len > 0);

    for (column_kinds) |allowed| {
        if (std.mem.eql(u8, allowed, kind)) {
            return true;
        }
    }

    return false;
}

/// The plugin's sections, checked against its own content types.
pub fn sections_of(comptime Plugin: type) []const Section {
    comptime {
        const name = Plugin.manifest.name;

        if (!@hasDecl(Plugin, "sections")) {
            return &.{};
        }

        const sections: []const Section = &Plugin.sections;
        const owned = @import("../plugin.zig").content_types_of(Plugin);

        if (sections.len > items_max) {
            @compileError("plugin " ++ name ++ ": `sections` holds at most 4");
        }

        for (sections) |section| {
            const counted = section.types.len > 0 and section.types.len <= section_types_max;

            if (section.label.len == 0 or section.icon.len == 0 or !counted) {
                @compileError("plugin " ++ name ++ ": a section needs a label, an icon and " ++
                    "1 to 8 types");
            }

            for (section.types) |listed| {
                check_section_type(name, owned, listed);
            }
        }

        return sections;
    }
}

fn check_section_type(
    comptime name: []const u8,
    comptime owned: anytype,
    comptime listed: SectionType,
) void {
    comptime {
        for (owned) |def| {
            if (!std.mem.eql(u8, def.handle, listed.handle)) {
                continue;
            }

            if (def.kind != .record or listed.columns.len > columns_max) {
                @compileError("plugin " ++ name ++ ": section type " ++ listed.handle ++
                    " is a record type with at most 4 columns");
            }

            for (listed.columns) |column| {
                if (!has_column(def.fields, column)) {
                    @compileError("plugin " ++ name ++ ": column " ++ column ++ " of " ++
                        listed.handle ++ " is a field of a kind a cell shows");
                }
            }

            return;
        }

        @compileError("plugin " ++ name ++ ": section type " ++ listed.handle ++
            " is not one of its content types");
    }
}

fn has_column(comptime fields: anytype, comptime column: []const u8) bool {
    comptime {
        std.debug.assert(column.len > 0);

        for (fields) |field| {
            if (std.mem.eql(u8, field.name, column)) {
                return column_kind(field.kind);
            }
        }

        return false;
    }
}

/// A box a plugin adds to a content type's edit form, any plugin's type or the core's: its
/// read draws it in the plugin frame, told only which record it is on (`In.record`, an id)
/// and the admin's base path, answering `html`. The plugin reads whatever else it needs
/// itself, as it may. Shown to whoever may call the read, on records of that type, when the
/// type is there.
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

        if (!@hasDecl(Plugin, "panels")) {
            return &.{};
        }

        const panels: []const Panel = &Plugin.panels;

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
    /// Fields drawn as several lines rather than one.
    multiline: []const []const u8 = &.{},
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

/// A section a plugin adds to a tab of System settings (`/admin/settings/system/<tab>`).
/// Plugins naming the same tab share it, their sections in plugin order; the tab shows
/// while any plugin adds to it. Compiled in only: `view.draw(session)` draws the section
/// with the admin's own components, and the plugin's routes take what it posts.
pub const SettingsTab = struct {
    /// Lowercase letters and dashes: `localization`.
    tab: []const u8,
    /// The tab's name: `Localization`. Plugins sharing a tab give the same one.
    tab_label: []const u8,
    /// A struct with `pub fn draw(session: *publr.admin.Session) publr.admin.Error!Node`.
    view: type,
    /// Shown to whoever may call this operation.
    operation: type,
};

pub const settings_tabs_max: u32 = 4;
/// The tabs System settings has of its own: a plugin's tab is named otherwise.
pub const own_settings_tabs = [_][]const u8{ "general", "currencies", "activity", "errors" };

/// The settings tab sections a plugin declares, checked.
pub fn settings_tabs_of(comptime Plugin: type) []const SettingsTab {
    comptime {
        const name = Plugin.manifest.name;

        std.debug.assert(name.len > 0);

        if (!@hasDecl(Plugin, "settings_tabs")) {
            return &.{};
        }

        const tabs: []const SettingsTab = &Plugin.settings_tabs;

        if (tabs.len == 0 or tabs.len > settings_tabs_max) {
            @compileError("plugin " ++ name ++ ": `settings_tabs` holds 1 to 4 sections");
        }

        for (tabs) |tab| {
            if (!valid_tab(tab.tab) or tab.tab_label.len == 0) {
                @compileError("plugin " ++ name ++ ": a settings tab is named in lowercase " ++
                    "letters and dashes, not one of System settings' own, and has a label");
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

/// The pages a plugin declares, each drawn by a read of its own.
pub fn pages_of(comptime Plugin: type) []const Page {
    comptime {
        const name = Plugin.manifest.name;

        if (!@hasDecl(Plugin, "pages")) {
            return &.{};
        }

        const pages: []const Page = &Plugin.pages;

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
