//! A plugin's menu items, `.menu = &.{orders_menu}`: what the admin's menu is built from. An
//! item opens one of the plugin's record types' lists (`.record = Orders.record`), one of its
//! pages (`.page`), or nothing (a heading); it sits under the first of `.parent` that exists.
//! Records and other plugins' items name it (`checkout.orders`) to sit under it: a parent
//! never knows its children.
const std = @import("std");
const plugin_define = @import("define.zig");
const record_define = @import("record_define.zig");
const content_type = @import("../../model/content_type.zig");
const sandboxed_plugin = @import("../../model/sandboxed_plugin.zig");
const Page = @import("admin_slots.zig").Page;

pub const MenuItem = struct {
    /// `[a-z][a-z0-9_]*`; others name it `<plugin>.<name>`.
    name: []const u8,
    /// `publr.t("Orders")`: translated like the plugin's other words.
    label: []const u8,
    icon: []const u8,
    page: ?Page = null,
    record: ?type = null,
    parent: []const []const u8 = &.{},
};

pub const items_max: u32 = 8;

/// An icon of the plugin's own: `.{ .name = "bag", .svg = @embedFile("icons/bag.svg") }`,
/// named `<plugin>.<name>` wherever an icon is given (`.icon = "products.bag"`). A 24×24
/// drawing in strokes of `currentColor`; sanitized as any SVG before a page shows it.
pub const Icon = struct {
    name: []const u8,
    svg: []const u8,
};

/// The plugin's own icons, checked: names, sizes, and that each is a drawing.
pub fn icons_of(comptime Plugin: type) []const sandboxed_plugin.PluginIcon {
    comptime {
        const plugin = Plugin.manifest.name;
        var icons: []const sandboxed_plugin.PluginIcon = &.{};

        std.debug.assert(plugin.len > 0);

        if (!plugin_define.has(Plugin, "icons")) {
            return &.{};
        }

        // A list of literals is a tuple: each entry read as an `Icon`.
        const given = Plugin.options.icons;

        if (given.len > sandboxed_plugin.plugin_icons_max) {
            @compileError("plugin " ++ plugin ++ ": `.icons` holds at most 16");
        }

        for (0..given.len) |index| {
            const icon: Icon = .{
                .name = given[index].name,
                .svg = given[index].svg,
            };
            const name = plugin ++ "." ++ icon.name;
            const drawing = std.mem.startsWith(u8, std.mem.trim(u8, icon.svg, " \n"), "<svg");

            if (!sandboxed_plugin.icon_name_valid(name)) {
                @compileError("plugin " ++ plugin ++ ": icon `" ++ icon.name ++ "` is named " ++
                    "with lowercase letters, digits, `_` and `-`");
            }

            if (!drawing or icon.svg.len > sandboxed_plugin.plugin_icon_bytes_max) {
                @compileError("plugin " ++ plugin ++ ": icon `" ++ icon.name ++ "` is an " ++
                    "`<svg>` of at most 4 KiB");
            }

            icons = icons ++ &[_]sandboxed_plugin.PluginIcon{.{
                .name = name,
                .svg = icon.svg,
            }};
        }

        const done = icons;

        return done;
    }
}

/// An icon given by name: one of the set (no dot), or one of the plugin's own.
fn check_icon(comptime Plugin: type, comptime what: []const u8, comptime name: []const u8) void {
    comptime {
        const plugin = Plugin.manifest.name;

        std.debug.assert(what.len > 0);

        if (std.mem.indexOfScalar(u8, name, '.') == null) {
            return;
        }

        for (icons_of(Plugin)) |icon| {
            if (std.mem.eql(u8, icon.name, name)) {
                return;
            }
        }

        @compileError("plugin " ++ plugin ++ ": " ++ what ++ " names icon `" ++ name ++
            "`, not one of the set nor in `.icons`");
    }
}

/// The text a menu item shows, marked for translation where it is written.
pub fn t(comptime text: []const u8) []const u8 {
    comptime {
        std.debug.assert(text.len > 0);

        return text;
    }
}

/// The plugin's menu items as the admin reads them, checked against its own records and pages.
pub fn entries_of(comptime Plugin: type) []const sandboxed_plugin.MenuEntry {
    comptime {
        const plugin = Plugin.manifest.name;
        var entries: []const sandboxed_plugin.MenuEntry = &.{};

        std.debug.assert(plugin.len > 0);

        if (!plugin_define.has(Plugin, "menu")) {
            return &.{};
        }

        const items: []const MenuItem = plugin_define.get(Plugin, "menu");

        if (items.len > items_max) {
            @compileError("plugin " ++ plugin ++ ": `.menu` holds at most 8 items");
        }

        for (items) |item| {
            entries = entries ++ &[_]sandboxed_plugin.MenuEntry{entry_of(Plugin, item)};
        }

        const done = entries;

        return done;
    }
}

fn entry_of(comptime Plugin: type, comptime item: MenuItem) sandboxed_plugin.MenuEntry {
    comptime {
        const plugin = Plugin.manifest.name;

        std.debug.assert(plugin.len > 0);

        const named = item.name.len > 0 and item.name.len <= 32 and
            std.mem.indexOfScalar(u8, item.name, '.') == null;

        if (!named or item.label.len == 0 or item.icon.len == 0) {
            @compileError("plugin " ++ plugin ++ ": a menu item needs a `.name` without a dot, " ++
                "a `.label` and an `.icon`");
        }

        if (item.page != null and item.record != null) {
            @compileError("plugin " ++ plugin ++ ": menu item " ++ item.name ++ " opens a " ++
                "page or a record type's list, not both");
        }

        check_icon(Plugin, "menu item " ++ item.name, item.icon);

        if (item.parent.len > content_type.menu_parents_max) {
            @compileError("plugin " ++ plugin ++ ": menu item " ++ item.name ++ " lists at " ++
                "most 8 parents");
        }

        return .{
            .name = plugin ++ "." ++ item.name,
            .label = item.label,
            .icon = item.icon,
            .record = if (item.record) |Record| record_of(Plugin, item.name, Record) else "",
            .page = if (item.page) |page| page_of(Plugin, item.name, page) else "",
            .parents = item.parent,
        };
    }
}

fn record_of(comptime Plugin: type, comptime item: []const u8, comptime Record: type) []const u8 {
    comptime {
        const plugin = Plugin.manifest.name;

        std.debug.assert(item.len > 0);

        const listed = plugin_define.has(Plugin, "records") and
            in_list(Plugin.options.records, Record);

        if (!record_define.is_definition(Record) or Record.is_internal or !listed) {
            @compileError("plugin " ++ plugin ++ ": menu item " ++ item ++ " opens one of " ++
                "the plugin's own content records, listed in `.records`");
        }

        return Record.type_name;
    }
}

fn page_of(comptime Plugin: type, comptime item: []const u8, comptime page: Page) []const u8 {
    comptime {
        const plugin = Plugin.manifest.name;

        std.debug.assert(item.len > 0);

        if (plugin_define.has(Plugin, "pages")) {
            for (plugin_define.get(Plugin, "pages")) |listed| {
                if (std.mem.eql(u8, listed.path, page.path)) {
                    return page.path;
                }
            }
        }

        @compileError("plugin " ++ plugin ++ ": menu item " ++ item ++ " opens a page " ++
            "listed in `.pages`");
    }
}

fn in_list(comptime list: anytype, comptime Wanted: type) bool {
    comptime {
        std.debug.assert(list.len <= 256);

        for (list) |Listed| {
            if (Listed == Wanted) {
                return true;
            }
        }

        return false;
    }
}

test "menu items: a heading, and one that opens the plugin's own record type" {
    const Order = struct {
        number: u32,
    };
    const Orders = struct {
        pub const publr_record_definition = true;
        pub const Doc = Order;
        pub const type_name = "order";
        pub const is_internal = false;
    };
    const Plugin = struct {
        pub const manifest = .{
            .name = "checkout",
        };
        pub const options = .{
            .records = .{Orders},
            .menu = [_]MenuItem{ .{
                .name = "shop",
                .label = t("Shop"),
                .icon = "bag",
            }, .{
                .name = "orders",
                .label = t("Orders"),
                .icon = "package",
                .record = Orders,
                .parent = &.{"checkout.shop"},
            } },
        };
        pub const source = struct {};
    };
    const entries = comptime entries_of(Plugin);

    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("checkout.orders", entries[1].name);
    try std.testing.expectEqualStrings("order", entries[1].record);
    try std.testing.expectEqualStrings("", entries[0].record);
    try std.testing.expectEqualStrings("checkout.shop", entries[1].parents[0]);
}
