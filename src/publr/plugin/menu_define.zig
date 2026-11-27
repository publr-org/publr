//! A plugin's menu items, `.menu = &.{orders_menu}`: what the admin's menu is built from. An
//! item opens one of the plugin's record types' lists (`.record = Orders.record`), one of its
//! pages (`.page`), or nothing (a heading); it sits under the first of `.parent` that exists.
//! Records and other plugins' items name it (`checkout.orders`) to sit under it: a parent
//! never knows its children.
const std = @import("std");
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

/// Words marked for translation where they are written: a menu item's text, a label another
/// plugin shows (`ctx.translate`). The text itself, at build or at run time.
pub fn t(comptime text: []const u8) []const u8 {
    comptime std.debug.assert(text.len > 0);
    comptime std.debug.assert(std.unicode.utf8ValidateSlice(text));

    return text;
}
