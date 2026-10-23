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
    only_one: []const []const u8 = &.{},
    /// The form's read offering items to add to its lists, and its read previewing a save.
    suggest: []const u8 = "",
    preview: []const u8 = "",
    /// Left out of the menu (`.menu = .none`); still opened at its address.
    hidden: bool = false,
    /// A tabbed page, drawn by the admin around the pages naming it in `parent`.
    tabs: bool = false,
    /// A tab of the first of these tabbed pages that exists: a form, or drawn by its
    /// `operation` under the tabbed page's tab bar.
    parent: []const []const u8 = &.{},
    /// A tab's primary action in its tabbed page's header; empty for none.
    action_label: []const u8 = "",
    action_href: []const u8 = "",

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
pub const users = admin_slots.users_page;

/// The tabbed page `tab` shows in, as `<plugin>.<path>`: the first of its `parent` that is a
/// tabbed page in `list`, else System settings. Null for a page that is not a tab.
pub fn parent_of(list: []const Page, tab: Page) ?[]const u8 {
    std.debug.assert(list.len <= pages_max);

    if (tab.parent.len == 0) {
        return null;
    }

    var buffer: [128]u8 = undefined;

    for (tab.parent) |wanted| {
        if (std.mem.eql(u8, wanted, system) or std.mem.eql(u8, wanted, users)) {
            return wanted;
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

/// What a tab shows over itself: its tabbed page's title, description and address, and the
/// tab bar, `page` lit. Core's own tabbed pages lead with their own tab.
pub fn Header(comptime Tab: type) type {
    return struct {
        title: []const u8,
        description: []const u8 = "",
        address: []const u8,
        tabs: []const Tab,
    };
}

pub fn header_of(
    comptime Tab: type,
    session: *Session,
    list: []const Page,
    page: Page,
    parent: []const u8,
) admin.Error!Header(Tab) {
    std.debug.assert(parent.len > 0);
    std.debug.assert(session.signed_in());

    var links: std.ArrayList(Tab) = .empty;
    var header: Header(Tab) = undefined;

    if (std.mem.eql(u8, parent, system) or std.mem.eql(u8, parent, users)) {
        const own = std.mem.eql(u8, parent, system);
        const address = if (own) "/admin/settings/system" else "/admin/settings/users";

        header = .{
            .title = try session.translated(if (own) "System settings" else "Users", .{}),
            .description = try session.translated(if (own)
                "How this Publr runs, and the conventions the site follows."
            else
                "Who may sign in, and what they may do.", .{}),
            .address = address,
            .tabs = &.{},
        };
        try links.append(session.arena, .{
            .label = try session.translated(if (own) "General" else "Users", .{}),
            .href = address,
            .active = false,
        });
    } else {
        var buffer: [128]u8 = undefined;
        const tabbed = for (list) |one| {
            if (one.tabs and std.mem.eql(u8, one.named(&buffer), parent)) {
                break one;
            }
        } else unreachable;

        header = .{
            .title = try session.declared(tabbed.label),
            .address = try tabbed.href(session.arena),
            .tabs = &.{},
        };
    }

    for (try tabs_of(session.arena, list, parent)) |tab| {
        try links.append(session.arena, .{
            .label = try session.declared(tab.label),
            .href = try tab.href(session.arena),
            .active = std.mem.eql(u8, tab.plugin, page.plugin) and
                std.mem.eql(u8, tab.path, page.path),
        });
    }

    header.tabs = links.items;

    return header;
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
                .only_one = page.only_one,
                .suggest = page.suggest,
                .preview = page.preview,
                .hidden = page.hidden,
                .tabs = page.tabs,
                .parent = page.parent,
                .action_label = page.action_label,
                .action_href = page.action_href,
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
            .only_one = if (page.form) |form| form.only_one else &.{},
            .suggest = if (page.form) |form| name_of(form.suggest) else "",
            .preview = if (page.form) |form| name_of(form.preview) else "",
            .hidden = page.menu != null,
            .tabs = page.tabs,
            .parent = page.parent,
            .action_label = if (page.action) |action| action.label else "",
            .action_href = if (page.action) |action| action.href else "",
        };
    }
}

fn name_of(comptime Operation: ?type) []const u8 {
    return if (Operation) |Named| Named.name else "";
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
/// filled by one of its reads and saved by one of its writes; only a tab has an action, to
/// an admin address.
fn sound(manifest: Manifest, page: ManifestPage) bool {
    std.debug.assert(manifest.name.len > 0);

    if (!admin_slots.is_page_path(page.path) or page.label.len == 0) {
        return false;
    }

    if (page.tabs) {
        return page.operation.len == 0 and page.read.len == 0 and page.parent.len == 0;
    }

    if (page.action_label.len > 0 or page.action_href.len > 0) {
        const to_admin = std.mem.startsWith(u8, page.action_href, "/admin/");

        if (page.parent.len == 0 or page.action_label.len == 0 or !to_admin) {
            return false;
        }
    }

    if (page.operation.len > 0) {
        return own_kind(manifest, page.operation) == .read and page.save.len == 0;
    }

    for ([_][]const u8{ page.suggest, page.preview }) |name| {
        if (name.len > 0 and own_kind(manifest, name) != .read) {
            return false;
        }
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

test "an installed plugin's form offers and previews only through reads of its own" {
    const own: Manifest = .{
        .name = "notes",
        .version = "0.1.0",
        .summary = "Notes",
        .operations = &.{
            .{
                .name = "notes.get",
                .kind = .read,
                .description = "Reads",
            },
            .{
                .name = "notes.save",
                .kind = .write,
                .description = "Saves",
            },
        },
    };
    const form: ManifestPage = .{
        .path = "settings",
        .label = "Notes",
        .icon = "file",
        .read = "notes.get",
        .save = "notes.save",
        .suggest = "notes.get",
        .preview = "notes.get",
    };
    var borrowed = form;
    var writing = form;

    borrowed.suggest = "user.list";
    writing.preview = "notes.save";

    try std.testing.expect(sound(own, form));
    try std.testing.expect(!sound(own, borrowed));
    try std.testing.expect(!sound(own, writing));
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

    var roles = notes;

    roles.parent = &.{"core.users"};
    try std.testing.expectEqualStrings(users, parent_of(&.{roles}, roles).?);

    const all_pages = [_]Page{ shop, currencies, notes };
    const tabs = try tabs_of(std.testing.allocator, &all_pages, "products.settings");
    defer std.testing.allocator.free(tabs);

    try std.testing.expectEqual(@as(usize, 1), tabs.len);
    try std.testing.expectEqualStrings("currencies", tabs[0].plugin);
}

test "a tabbed page in a manifest draws nothing itself; a tab is a form or a drawn page" {
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
    var acting = drawn_tab;
    var leaving = drawn_tab;
    var untabbed = drawn_tab;

    drawing.operation = "shop.page";
    acting.action_label = "Add";
    acting.action_href = "/admin/plugin/shop/add";
    leaving.action_label = "Add";
    leaving.action_href = "https://example.com/add";
    untabbed.parent = &.{};
    untabbed.action_label = "Add";
    untabbed.action_href = "/admin/plugin/shop/add";

    try std.testing.expect(sound(own, tabbed));
    try std.testing.expect(!sound(own, drawing));
    try std.testing.expect(sound(own, drawn_tab));
    try std.testing.expect(sound(own, acting));
    try std.testing.expect(!sound(own, leaving));
    try std.testing.expect(!sound(own, untabbed));
}
