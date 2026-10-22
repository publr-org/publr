//! The admin's menu as plugins build it (`publr.MenuItem`): each item with no parent that
//! exists is a part of the admin of its own on the rail, holding the record types' lists and
//! pages under it, left out of the Content sidebar. An item opens a record type's list, a
//! page, or nothing; a content type sits under the first of its `menu.parents` that exists,
//! whichever plugin declared it. Compiled-in plugins' items from the build, installed ones'
//! from their manifests; a section shows only what the viewer sees, and none when that is
//! nothing.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const types = @import("../../operations/content_type.zig");
const filters = @import("content/filters.zig");
const nav = @import("nav.zig");

const Session = admin.Session;
const Error = admin.Error;
const Summary = types.Summary;
const MenuEntry = model.sandboxed_plugin.MenuEntry;

pub const sections_max: u32 = 32;
pub const entries_max: u32 = 128;
/// How deep items nest; a chain longer than this, or one that loops, stops where it is.
const depth_max: u32 = 8;

pub const Type = struct {
    /// The record type's handle; empty for a page.
    handle: []const u8,
    label: []const u8,
    href: []const u8,
    /// The heading it opens in the section's sidebar; empty for the rest of a group.
    heading: []const u8 = "",
    icon: []const u8 = "file",
};

pub const Section = struct {
    plugin: []const u8,
    /// The menu item it is: `checkout.orders`.
    name: []const u8,
    label: []const u8,
    icon: []const u8,
    types: []const Type,

    /// Where it opens: its first entry.
    pub fn href(section: Section) []const u8 {
        std.debug.assert(section.types.len > 0);

        return section.types[0].href;
    }

    pub fn has(section: Section, handle: []const u8) bool {
        std.debug.assert(section.types.len > 0);

        return section.find(handle) != null;
    }

    pub fn find(section: Section, handle: []const u8) ?Type {
        std.debug.assert(handle.len > 0);

        for (section.types) |one| {
            if (std.mem.eql(u8, one.handle, handle)) {
                return one;
            }
        }

        return null;
    }
};

/// Every menu item a plugin brings: compiled-in plugins' first, in name order.
fn entries_of(session: *const Session) Error![]const MenuEntry {
    std.debug.assert(session.signed_in());

    var entries: std.ArrayList(MenuEntry) = .empty;

    try entries.appendSlice(session.arena, registry.menu);

    const sandboxed = session.ctx.sandboxed_plugins orelse return entries.items;

    for (sandboxed.manifests()) |manifest| {
        for (manifest.menu) |entry| {
            if (entries.items.len == entries_max) {
                return entries.items;
            }

            try entries.append(session.arena, entry);
        }
    }

    return entries.items;
}

/// Every section the viewer sees, in the order their items are declared.
pub fn all(session: *const Session) Error![]const Section {
    std.debug.assert(session.signed_in());

    const entries = try entries_of(session);

    if (entries.len == 0) {
        return &.{};
    }

    var reading = session.*;
    const listed = registry.SDK.dispatch(&reading.ctx, types.List, .{
        .limit = @import("../../sdk/operation.zig").page_limit_max,
    }) catch return error.OutOfMemory;
    var shown: std.ArrayList(Section) = .empty;

    for (entries, 0..) |entry, position| {
        const index: u32 = @intCast(position);

        if (top_of(entries, index) != index or shown.items.len == sections_max) {
            continue;
        }

        const within = try entries_under(session, entries, index, listed.types);

        if (within.len > 0) {
            try shown.append(session.arena, .{
                .plugin = plugin_of(entry.name),
                .name = entry.name,
                .label = entry.label,
                .icon = entry.icon,
                .types = within,
            });
        }
    }

    return shown.items;
}

/// One thing a section lists, and the heading it sits under: the item right under the top
/// on its way up; null for what sits on the top itself.
const Placed = struct {
    group: ?u32,
    /// The plugin it comes from: a heading lists its own plugin's first.
    owner: []const u8,
    entry: Type,
};

/// What a section holds, as its sidebar lists it: what sits on the top item first, then
/// each heading (an item right under the top) with what sits under it, the top's own plugin's
/// headings first; only what the viewer sees, and a heading only over something.
fn entries_under(
    session: *const Session,
    entries: []const MenuEntry,
    top: u32,
    listed: []const Summary,
) Error![]const Type {
    std.debug.assert(top < entries.len);
    std.debug.assert(entries.len <= entries_max);

    const placed = try placed_under(session, entries, top, listed);
    var within: std.ArrayList(Type) = .empty;

    const owner = plugin_of(entries[top].name);

    try append_group(session, &within, placed, null, "", owner);

    for ([_]bool{ true, false }) |own| {
        for (entries, 0..) |entry, position| {
            const index: u32 = @intCast(position);
            const heading = index != top and group_of(entries, index) == index and
                top_of(entries, index) == top;
            const mine = std.mem.eql(u8, plugin_of(entry.name), owner);

            if (heading and mine == own) {
                const from = plugin_of(entry.name);

                try append_group(session, &within, placed, index, entry.label, from);
            }
        }
    }

    return within.items;
}

/// Everything under `top`, each with its heading: items' own lists and pages, then types
/// placed by their `menu.parents`.
fn placed_under(
    session: *const Session,
    entries: []const MenuEntry,
    top: u32,
    listed: []const Summary,
) Error![]const Placed {
    std.debug.assert(top < entries.len);
    std.debug.assert(listed.len <= std.math.maxInt(u32));

    var placed: std.ArrayList(Placed) = .empty;

    for (entries, 0..) |entry, position| {
        const index: u32 = @intCast(position);

        if (top_of(entries, index) != top) {
            continue;
        }

        const opened = if (entry.record.len > 0)
            if (summary_of(listed, entry.record)) |summary|
                try type_of(session, summary, summary.name)
            else
                null
        else if (entry.page.len > 0)
            try page_of(session, entry)
        else
            null;

        if (opened) |one| {
            try placed.append(session.arena, .{
                .group = group_of(entries, index),
                .owner = plugin_of(entry.name),
                .entry = one,
            });
        }
    }

    for (listed) |summary| {
        if (summary.menu_hidden) {
            continue;
        }

        const parent = first_existing(entries, summary.menu_parents) orelse continue;

        if (top_of(entries, parent) == top) {
            if (try type_of(session, summary, summary.name)) |one| {
                try placed.append(session.arena, .{
                    .group = group_of(entries, parent),
                    .owner = summary.owner,
                    .entry = one,
                });
            }
        }
    }

    return placed.items;
}

/// The entries of one heading, its own plugin's first, the heading named on the first; a
/// type listed once.
fn append_group(
    session: *const Session,
    within: *std.ArrayList(Type),
    placed: []const Placed,
    group: ?u32,
    heading: []const u8,
    owner: []const u8,
) Error!void {
    std.debug.assert(placed.len <= entries_max + 4096);
    std.debug.assert(group == null or heading.len > 0);

    var first = true;

    for ([_]bool{ true, false }) |own| {
        for (placed) |one| {
            const mine = std.mem.eql(u8, one.owner, owner);

            const elsewhere = one.group != group or mine != own;

            if (elsewhere or listed_already(within.items, one.entry.handle)) {
                continue;
            }

            var entry = one.entry;

            entry.heading = if (first) heading else "";
            first = false;
            try within.append(session.arena, entry);
        }
    }
}

fn listed_already(within: []const Type, handle: []const u8) bool {
    std.debug.assert(within.len <= entries_max + 4096);

    if (handle.len == 0) {
        return false;
    }

    for (within) |one| {
        if (std.mem.eql(u8, one.handle, handle)) {
            return true;
        }
    }

    return false;
}

/// A record type's list, opening at its default view; null for any other kind.
fn type_of(session: *const Session, summary: Summary, label: []const u8) Error!?Type {
    std.debug.assert(summary.handle.len > 0);
    std.debug.assert(label.len > 0);

    if (summary.kind != .record) {
        return null;
    }

    const start: model.view.Filters = .{
        .types = &.{summary.handle},
        .type_view = true,
    };

    return .{
        .handle = summary.handle,
        .label = label,
        .href = try filters.format(session.arena, start, null),
        .icon = if (summary.icon.len > 0) summary.icon else "file",
    };
}

fn page_of(session: *const Session, entry: MenuEntry) Error!Type {
    std.debug.assert(entry.page.len > 0);
    std.debug.assert(entry.label.len > 0);

    return .{
        .handle = "",
        .icon = entry.icon,
        .label = entry.label,
        .href = try std.fmt.allocPrint(session.arena, "/admin/plugin/{s}/{s}", .{
            plugin_of(entry.name),
            entry.page,
        }),
    };
}

/// The item right under the top on the way up from `index`; null when `index` is the top.
fn group_of(entries: []const MenuEntry, index: u32) ?u32 {
    std.debug.assert(index < entries.len);
    std.debug.assert(entries.len <= entries_max);

    var at = index;
    var below: ?u32 = null;

    for (0..depth_max) |_| {
        const parent = first_existing(entries, entries[at].parents) orelse return below;

        if (parent == index) {
            return below;
        }

        below = at;
        at = parent;
    }

    return below;
}

/// The item a chain of first-existing parents ends at, from `index`.
fn top_of(entries: []const MenuEntry, index: u32) u32 {
    std.debug.assert(index < entries.len);
    std.debug.assert(entries.len <= entries_max);

    var at = index;

    for (0..depth_max) |_| {
        const parent = first_existing(entries, entries[at].parents) orelse return at;

        if (parent == index) {
            return at;
        }

        at = parent;
    }

    return at;
}

/// The position of the first of `names` that is a declared item.
fn first_existing(entries: []const MenuEntry, names: []const []const u8) ?u32 {
    std.debug.assert(names.len <= model.content_type.menu_parents_max);
    std.debug.assert(entries.len <= entries_max);

    for (names) |name| {
        for (entries, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.name, name)) {
                return @intCast(index);
            }
        }
    }

    return null;
}

fn summary_of(listed: []const Summary, handle: []const u8) ?Summary {
    std.debug.assert(handle.len > 0);
    std.debug.assert(listed.len <= std.math.maxInt(u32));

    for (listed) |summary| {
        if (std.mem.eql(u8, summary.handle, handle)) {
            return summary;
        }
    }

    return null;
}

/// `checkout.orders` is checkout's.
fn plugin_of(name: []const u8) []const u8 {
    std.debug.assert(name.len > 0);

    const dot = std.mem.indexOfScalar(u8, name, '.') orelse return name;

    std.debug.assert(dot > 0);

    return name[0..dot];
}

/// The section a content page is in: the one holding the single type it shows.
pub fn current(sections: []const Section, content: nav.Current) ?Section {
    std.debug.assert(sections.len <= sections_max);

    const shown = content.filters.types;

    if (content.view_id != null or shown.len != 1) {
        return null;
    }

    for (sections) |section| {
        if (section.has(shown[0])) {
            return section;
        }
    }

    return null;
}

/// Whether a type belongs to a section, so the Content sidebar leaves it out.
pub fn holds(sections: []const Section, handle: []const u8) bool {
    std.debug.assert(sections.len <= sections_max);

    for (sections) |section| {
        if (section.has(handle)) {
            return true;
        }
    }

    return false;
}

/// The section's sidebar, drawn as Settings' is: each heading over its group, the page shown
/// lit.
pub fn sidebar_of(
    session: *const Session,
    section: Section,
    content: nav.Current,
) Error!admin.render.Node {
    std.debug.assert(session.signed_in());
    std.debug.assert(section.types.len > 0);

    const Item = admin.views.SettingsNav.PagesItem;
    const Icon = @FieldType(Item, "icon");
    const icons = @import("plugin_icons.zig");
    const items = try session.arena.alloc(Item, section.types.len);
    const lit = if (content.filters.types.len == 1) content.filters.types[0] else "";

    for (section.types, items) |one, *item| {
        const picked = icons.pick(Icon, session, one.icon, .file);

        item.* = .{
            .label = one.label,
            .href = one.href,
            .icon = picked.icon,
            .custom_icon = picked.custom_icon,
            .active = one.handle.len > 0 and std.mem.eql(u8, one.handle, lit),
            .plugin = "",
            .page = "",
            .pinned = false,
            .shared = false,
            .count = "",
            .group = one.heading,
            .heading = "",
        };
    }

    return admin.render.view(session.arena, admin.views.SettingsNav, .{
        .pages = items,
        .csrf = session.csrf_token(),
        .back = section.href(),
        .admin = session.ctx.caller.holds("admin"),
    });
}

/// The section's heading, Settings' own: its icon turns into a way back on hover.
pub fn heading_of(session: *const Session, section: Section) Error!admin.render.Node {
    std.debug.assert(session.signed_in());

    const Heading = admin.views.SidebarHeading;
    const Icon = @FieldType(Heading.Props, "icon");
    const picked = @import("plugin_icons.zig").pick(Icon, session, section.icon, .package);

    return admin.render.view(session.arena, Heading, .{
        .href = section.href(),
        .label = section.label,
        .icon = picked.icon,
        .custom_icon = picked.custom_icon,
        .back = true,
    });
}
