//! Plugins' own pages: compiled-in plugins' from the build, installed ones' from their
//! manifests, in the same shape. A page is listed and drawn for whoever may call the read
//! that draws it; an installed plugin's page naming an operation that is not its own is
//! never found.
const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const admin_slots = @import("../../../sdk/plugin/admin_slots.zig");

const Session = admin.Session;

pub const pages_max: u32 = 64;
pub const operations_max: u32 = 256;

pub const Page = struct {
    plugin: []const u8,
    path: []const u8,
    label: []const u8,
    icon: []const u8,
    /// The read that draws it in the frame; empty for a form by declaration.
    operation: []const u8,
    /// A form by declaration: the read that fills it, the write that saves it.
    read: []const u8 = "",
    save: []const u8 = "",
    /// Left out of the menu (`.menu = .none`); still opened at its address.
    hidden: bool = false,
    /// A tabbed page, drawn by the admin around the pages naming it in `parent`.
    tabs: bool = false,
    /// A form that is a tab of the first of these tabbed pages that exists.
    parent: []const []const u8 = &.{},

    pub fn declared(page: Page) bool {
        std.debug.assert(page.path.len > 0);

        return page.save.len > 0;
    }

    /// The operation that decides who sees it; none for a tabbed page, shown while a tab is.
    pub fn gate(page: Page) []const u8 {
        std.debug.assert(page.operation.len > 0 or page.read.len > 0 or page.tabs);

        return if (page.operation.len > 0) page.operation else page.read;
    }

    /// `<plugin>.<path>`, as a tab's `parent` names it, in `buffer`.
    pub fn named(page: Page, buffer: []u8) []const u8 {
        std.debug.assert(buffer.len >= 64 + 1 + admin_slots.page_path_len_max);

        return std.fmt.bufPrint(buffer, "{s}.{s}", .{ page.plugin, page.path }) catch "";
    }

    /// Where it opens.
    pub fn href(page: Page, arena: std.mem.Allocator) admin.Error![]const u8 {
        std.debug.assert(page.plugin.len > 0);

        return std.fmt.allocPrint(arena, prefix ++ "/{s}/{s}", .{ page.plugin, page.path });
    }
};

const prefix = "/admin/plugin";
pub const system = admin_slots.system_page;

/// The tabbed page `tab` shows in, as `<plugin>.<path>`: the first of its `parent` that is a
/// tabbed page in `list`, else System settings. Null for a page that is not a tab.
pub fn parent_of(list: []const Page, tab: Page) ?[]const u8 {
    std.debug.assert(list.len <= pages_max);

    if (tab.parent.len == 0) {
        return null;
    }

    var buffer: [128]u8 = undefined;

    for (tab.parent) |wanted| {
        if (std.mem.eql(u8, wanted, system)) {
            return system;
        }

        for (list) |page| {
            if (page.tabs and std.mem.eql(u8, page.named(&buffer), wanted)) {
                return wanted;
            }
        }
    }

    return system;
}

/// The tabs of the tabbed page `name` the viewer may open, in `list`'s order.
pub fn tabs_of(
    arena: std.mem.Allocator,
    list: []const Page,
    name: []const u8,
) admin.Error![]const Page {
    std.debug.assert(name.len > 0);

    var found: std.ArrayList(Page) = .empty;

    for (list) |page| {
        const under = parent_of(list, page) orelse continue;

        if (std.mem.eql(u8, under, name)) {
            try found.append(arena, page);
        }
    }

    return found.toOwnedSlice(arena);
}

/// Every page the viewer may open, compiled-in plugins' first, in name order. A tabbed page
/// is always there, so tabs find it; it shows while one of its tabs does.
pub fn all(session: *const Session) admin.Error![]const Page {
    std.debug.assert(session.signed_in());
    comptime std.debug.assert(registry.pages.len <= pages_max);

    var list: std.ArrayList(Page) = .empty;

    inline for (registry.pages) |owned| {
        if (comptime owned.page.tabs) {
            try list.append(session.arena, comptime native(owned));
        } else if (registry.SDK.may(&session.ctx, comptime owned.page.gate())) {
            try list.append(session.arena, comptime native(owned));
        }
    }

    for (manifests_of(session)) |manifest| {
        for (manifest.pages) |page| {
            if (list.items.len == pages_max) {
                break;
            }

            const shown: Page = .{
                .plugin = manifest.name,
                .path = page.path,
                .label = page.label,
                .icon = page.icon,
                .operation = page.operation,
                .read = page.read,
                .save = page.save,
                .hidden = page.hidden,
                .tabs = page.tabs,
                .parent = page.parent,
            };
            const may = page.tabs or registry.SDK.may_named(&session.ctx, shown.gate());

            if (sound(manifest, page) and may) {
                try list.append(session.arena, shown);
            }
        }
    }

    return list.items;
}

fn native(comptime owned: @import("../../../sdk/plugin.zig").OwnedPage) Page {
    comptime {
        const page = owned.page;

        std.debug.assert(owned.plugin.len > 0);

        return .{
            .plugin = owned.plugin,
            .path = page.path,
            .label = page.label,
            .icon = page.icon,
            .operation = if (page.operation) |Operation| Operation.name else "",
            .read = if (page.form) |form| form.read.name else "",
            .save = if (page.form) |form| form.save.name else "",
            .hidden = page.menu != null,
            .tabs = page.tabs,
            .parent = page.parent,
        };
    }
}

/// The page at `path` of `plugin`, when the viewer may open it.
pub fn find(session: *const Session, plugin: []const u8, path: []const u8) admin.Error!?Page {
    std.debug.assert(session.signed_in());
    std.debug.assert(plugin.len > 0);

    for (try all(session)) |page| {
        if (std.mem.eql(u8, page.plugin, plugin) and std.mem.eql(u8, page.path, path)) {
            return page;
        }
    }

    return null;
}

/// The operations of `plugin`'s own: the only ones its frame may ask the admin to run.
pub fn operations_of(session: *const Session, plugin: []const u8) admin.Error![]const []const u8 {
    std.debug.assert(session.signed_in());
    std.debug.assert(plugin.len > 0);

    var list: std.ArrayList([]const u8) = .empty;
    const owners = registry.registry.operation_owners;

    inline for (registry.SDK.operations, 0..) |Operation, index| {
        if (std.mem.eql(u8, owners[index], plugin)) {
            try list.append(session.arena, Operation.name);
        }
    }

    for (manifests_of(session)) |manifest| {
        if (!std.mem.eql(u8, manifest.name, plugin)) {
            continue;
        }

        for (manifest.operations) |operation| {
            if (list.items.len < operations_max) {
                try list.append(session.arena, operation.name);
            }
        }
    }

    return list.items;
}

const Manifest = @import("../../../sdk/sandboxed_plugins.zig").Manifest;
const ManifestPage = @import("../../../model/sandboxed_plugin.zig").Page;

fn manifests_of(session: *const Session) []const Manifest {
    std.debug.assert(session.ctx.now_ms > 0);

    const sandboxed = session.ctx.sandboxed_plugins orelse return &.{};
    const manifests = sandboxed.manifests();

    std.debug.assert(manifests.len <= @import("../../../model/sandboxed_plugin.zig")
        .sandboxed_plugins_max);

    return manifests;
}

/// A manifest's page is a page path drawn by one of the plugin's own reads, or a form
/// filled by one of its reads and saved by one of its writes.
fn sound(manifest: Manifest, page: ManifestPage) bool {
    std.debug.assert(manifest.name.len > 0);

    if (!admin_slots.is_page_path(page.path) or page.label.len == 0) {
        return false;
    }

    if (page.tabs) {
        return page.operation.len == 0 and page.read.len == 0 and page.parent.len == 0;
    }

    if (page.parent.len > 0 and page.save.len == 0) {
        return false;
    }

    if (page.operation.len > 0) {
        return own_kind(manifest, page.operation) == .read and page.save.len == 0;
    }

    return own_kind(manifest, page.read) == .read and own_kind(manifest, page.save) == .write;
}

const Kind = @import("../../../model/sandboxed_plugin.zig").Kind;

fn own_kind(manifest: Manifest, name: []const u8) ?Kind {
    std.debug.assert(manifest.name.len > 0);

    for (manifest.operations) |operation| {
        if (std.mem.eql(u8, operation.name, name)) {
            return operation.kind;
        }
    }

    return null;
}

test "an installed plugin's page drawn by another's operation is not sound" {
    const own: Manifest = .{
        .name = "notes",
        .version = "0.1.0",
        .summary = "Notes",
        .operations = &.{.{
            .name = "notes.page",
            .kind = .read,
            .description = "Draws",
        }},
    };
    const page: ManifestPage = .{
        .path = "all",
        .label = "Notes",
        .icon = "file",
        .operation = "notes.page",
    };
    var borrowed = page;
    var bad_path = page;

    borrowed.operation = "user.list";
    bad_path.path = "../x";

    try std.testing.expect(sound(own, page));
    try std.testing.expect(!sound(own, borrowed));
    try std.testing.expect(!sound(own, bad_path));
}

test "a tab shows in the first tabbed page of its parents that exists, else System settings" {
    const shop: Page = .{
        .plugin = "products",
        .path = "settings",
        .label = "Shop settings",
        .icon = "gear",
        .operation = "",
        .tabs = true,
    };
    const currencies: Page = .{
        .plugin = "currencies",
        .path = "currencies",
        .label = "Currencies",
        .icon = "coins",
        .operation = "",
        .read = "currencies.list",
        .save = "currencies.save",
        .parent = &.{ "products.settings", "core.system" },
    };
    const notes: Page = .{
        .plugin = "notes",
        .path = "all",
        .label = "Notes",
        .icon = "file",
        .operation = "notes.page",
    };
    var lost = currencies;

    lost.parent = &.{"orders.settings"};

    const placed = parent_of(&.{ shop, currencies }, currencies).?;

    try std.testing.expectEqualStrings("products.settings", placed);
    try std.testing.expectEqualStrings(system, parent_of(&.{currencies}, currencies).?);
    try std.testing.expectEqualStrings(system, parent_of(&.{ shop, lost }, lost).?);
    try std.testing.expect(parent_of(&.{notes}, notes) == null);

    const all_pages = [_]Page{ shop, currencies, notes };
    const tabs = try tabs_of(std.testing.allocator, &all_pages, "products.settings");
    defer std.testing.allocator.free(tabs);

    try std.testing.expectEqual(@as(usize, 1), tabs.len);
    try std.testing.expectEqualStrings("currencies", tabs[0].plugin);
}

test "a tabbed page in a manifest draws nothing itself; a tab is a form" {
    const own: Manifest = .{
        .name = "shop",
        .version = "0.1.0",
        .summary = "Shop",
        .operations = &.{
            .{
                .name = "shop.read",
                .kind = .read,
                .description = "Reads",
            },
            .{
                .name = "shop.page",
                .kind = .read,
                .description = "Draws",
            },
        },
    };
    const tabbed: ManifestPage = .{
        .path = "settings",
        .label = "Shop settings",
        .icon = "gear",
        .tabs = true,
    };
    const drawn_tab: ManifestPage = .{
        .path = "drawn",
        .label = "Drawn",
        .icon = "file",
        .operation = "shop.page",
        .parent = &.{"shop.settings"},
    };
    var drawing = tabbed;

    drawing.operation = "shop.page";

    try std.testing.expect(sound(own, tabbed));
    try std.testing.expect(!sound(own, drawing));
    try std.testing.expect(!sound(own, drawn_tab));
}
