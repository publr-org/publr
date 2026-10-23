//! Where a plugin shows in the admin. Any plugin: its own pages, shown in the plugin frame
//! and listed in the Settings sidebar or as tabs of a tabbed page, sections, panels, an item
//! in the top bar, and actions on the rows of another plugin's page. The top bar item is a
//! function the admin calls for every signed-in page; a row action is data the page's owner
//! reads.
const std = @import("std");
const plugin_define = @import("define.zig");

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
    /// A tabbed page: the admin draws it, its title over a tab bar and the open tab, and
    /// other plugins' pages fill it by naming it in `.parent`. No operation or form.
    tabs: bool = false,
    /// A tab of the first tabbed page named here that exists (`"products.settings"`, System
    /// settings `"core.system"`, Users `"core.users"`), else of System settings. A tab is a
    /// `.form`, or drawn by its `operation` in the frame under the tabbed page's tab bar.
    parent: []const []const u8 = &.{},
    /// A tab's primary action, in its tabbed page's header while it is open: `.{ .label =
    /// "Add role", .href = "/admin/roles/add" }`, an address in the admin.
    action: ?Action = null,

    /// The operation that decides who sees the page: the drawing read, or the form's.
    pub fn gate(comptime page: Page) type {
        comptime {
            std.debug.assert(!page.tabs);

            return page.operation orelse page.form.?.read;
        }
    }
};

pub const Action = struct {
    label: []const u8,
    href: []const u8,
};

/// System settings, the tabbed page every Publr has: a tab's parent when none named exists.
pub const system_page = "core.system";
/// Users, the other tabbed page of core's: its own Users tab first.
pub const users_page = "core.users";

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

            if (page.tabs) {
                @compileError("plugin " ++ name ++ ": tabbed page " ++ page.path ++
                    " is not in the top bar; its tabs may be");
            }

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
    /// A list's boolean columns true in one row only, drawn as a choice between the rows:
    /// the main language.
    only_one: []const []const u8 = &.{},
    /// A read of the plugin's own, no input, answering items people often add to the
    /// form's lists, by list (`.{ .languages = ... }`): each list offers them to pick.
    suggest: ?type = null,
    /// A read of the plugin's own taking `save`'s input and answering as `read` does: a
    /// list's columns `save` does not take (an example) follow what people type.
    preview: ?type = null,
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

            if (page.tabs) {
                assert_tabbed(name, page);
                continue;
            }

            if ((page.operation == null) == (page.form == null)) {
                @compileError("plugin " ++ name ++ ": page " ++ page.path ++
                    " is drawn by an `operation` or declared as a `form`, one of them");
            }

            if (page.parent.len > 0) {
                assert_tab(name, page);
            } else if (page.action != null) {
                @compileError("plugin " ++ name ++ ": page " ++ page.path ++
                    " has an action only as a tab: its own view draws its actions");
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

fn assert_tabbed(comptime plugin: []const u8, comptime page: Page) void {
    comptime {
        const label = "plugin " ++ plugin ++ ": tabbed page " ++ page.path;

        if (page.operation != null or page.form != null) {
            @compileError(label ++ " draws nothing itself: no `operation` or `form`");
        }

        if (page.parent.len > 0) {
            @compileError(label ++ " is not a tab of another");
        }
    }
}

/// A tab names pages `<plugin>.<path>` (`core.system`); its action goes to an admin address.
fn assert_tab(comptime plugin: []const u8, comptime page: Page) void {
    comptime {
        const label = "plugin " ++ plugin ++ ": page " ++ page.path;

        if (page.action) |action| {
            if (action.label.len == 0 or !std.mem.startsWith(u8, action.href, "/admin/")) {
                @compileError(label ++ ": its action has a label and goes to /admin/…");
            }
        }

        for (page.parent) |named| {
            const dot = std.mem.indexOfScalar(u8, named, '.') orelse
                @compileError(label ++ ": parent \"" ++ named ++ "\" is `<plugin>.<path>`");

            if (dot == 0 or !is_page_path(named[dot + 1 ..])) {
                @compileError(label ++ ": parent \"" ++ named ++ "\" is `<plugin>.<path>`");
            }
        }
    }
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

        if (form.suggest) |Suggest| {
            if (Suggest.kind != .read or @typeInfo(Suggest.In).@"struct".fields.len != 0) {
                @compileError(label ++ Suggest.name ++ " is a read with no input");
            }
        }

        if (form.preview) |Preview| {
            if (Preview.kind != .read or Preview.In != form.save.In) {
                @compileError(label ++ Preview.name ++ " is a read taking " ++
                    form.save.name ++ "'s input");
            }
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
