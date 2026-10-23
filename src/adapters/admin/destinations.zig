//! The pages a person may pin to their rail, as the sidebars list them and the rail draws
//! the pinned ones: the admin's own under Settings, plugins' settings pages and pages, the
//! settings sections, and plugins' sections in Content. Each named as `rail.pin` takes it,
//! shown only to whoever may see it.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const rail = @import("../../operations/rail.zig");
const secret = @import("../../operations/secret.zig");
const types = @import("../../operations/content_type.zig");
const update = @import("../../operations/update.zig");
const chrome = @import("chrome.zig");
const frame = @import("frame.zig");
const sections = @import("sections.zig");

const Session = admin.Session;
const Error = admin.Error;

pub const Destination = struct {
    plugin: []const u8,
    page: []const u8,
    label: []const u8,
    icon: []const u8,
    href: []const u8,
    pinned: bool = false,
    /// Pinned by an administrator for everyone.
    shared: bool = false,
    /// Where Settings lists it.
    group: model.admin_pages.Group = .general,
    /// The app a settings section belongs to; empty for a Global one and the rest.
    app: []const u8 = "",
};

/// Everything Settings lists, in its order.
pub fn settings(session: *const Session) Error![]Destination {
    std.debug.assert(session.signed_in());

    var listed: std.ArrayList(Destination) = .empty;
    const arena = session.arena;

    for (model.admin_pages.all) |page| {
        if (sees(session, page.who)) {
            const href = try std.fmt.allocPrint(arena, "/admin/{s}", .{page.page});

            try listed.append(arena, .{
                .plugin = "",
                .page = page.page,
                .label = page.label,
                .icon = page.icon,
                .href = href,
                .group = page.group,
            });
        }
    }

    inline for (registry.settings_pages) |owned| {
        if (registry.SDK.may(&session.ctx, owned.page.operation)) {
            try listed.append(arena, .{
                .plugin = owned.plugin,
                .page = owned.page.path,
                .label = owned.page.label,
                .icon = owned.page.icon,
                .href = owned.page.path,
                .group = .plugins,
            });
        }
    }

    const pages = try frame.all(session);

    for (pages) |page| {
        if (page.hidden or page.parent.len > 0) {
            continue;
        }

        if (page.tabs) {
            var buffer: [128]u8 = undefined;
            const tabs = try frame.tabs_of(arena, pages, page.named(&buffer));

            if (tabs.len == 0) {
                continue;
            }
        }

        const href = try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{
            frame.prefix,
            page.plugin,
            page.path,
        });

        try listed.append(arena, .{
            .plugin = page.plugin,
            .page = page.path,
            .label = page.label,
            .icon = page.icon,
            .href = href,
            .group = .plugins,
        });
    }

    try append_settings_sections(session, &listed);
    std.sort.insertion(Destination, listed.items, {}, listed_before);
    try mark_pinned(session, listed.items);

    return listed.items;
}

/// Settings' order: by group, and in Apps the sections by their app, each kept in the order
/// it was added.
fn listed_before(_: void, left: Destination, right: Destination) bool {
    std.debug.assert(left.page.len > 0);
    std.debug.assert(right.page.len > 0);

    const left_group = @intFromEnum(left.group);
    const right_group = @intFromEnum(right.group);

    if (left_group != right_group) {
        return left_group < right_group;
    }

    return std.mem.lessThan(u8, left.app, right.app);
}

/// Plugins' sections, as Content lists them.
pub fn content(session: *const Session, all: []const sections.Section) Error![]Destination {
    std.debug.assert(session.signed_in());

    const listed = try session.arena.alloc(Destination, all.len);

    for (all, listed) |section, *destination| {
        destination.* = .{
            .plugin = section.plugin,
            .page = try section_page(session.arena, section),
            .label = section.label,
            .icon = section.icon,
            .href = section.href(),
        };
    }

    try mark_pinned(session, listed);

    return listed;
}

/// A section's name for a pin: its menu item's, under its plugin (`products`, `section/shop`).
pub fn section_page(arena: std.mem.Allocator, section: sections.Section) Error![]const u8 {
    std.debug.assert(section.types.len > 0);
    std.debug.assert(section.name.len > section.plugin.len);

    const local = section.name[section.plugin.len + 1 ..];

    return std.fmt.allocPrint(arena, "section/{s}", .{local});
}

const RailEntry = admin.views.RailEntries.EntriesItem;

pub const Rail = struct {
    node: ?admin.render.Node,
    lit: bool,
};

/// The person's pins that lead somewhere they may go, in their order; the one the page is
/// under lit (the section the page is in, for a section).
pub fn rail_of(
    session: *Session,
    path: []const u8,
    all_sections: []const sections.Section,
    in: ?sections.Section,
) Error!Rail {
    std.debug.assert(session.signed_in());
    std.debug.assert(path.len > 0);

    const pins = registry.SDK.dispatch(&session.ctx, rail.List, .{}) catch return .{
        .node = null,
        .lit = false,
    };

    if (pins.pins.len == 0) {
        return .{
            .node = null,
            .lit = false,
        };
    }

    const known = try settings(session);
    const in_content = try content(session, all_sections);
    const in_page = if (in) |section| try section_page(session.arena, section) else "";
    var shown: std.ArrayList(RailEntry) = .empty;
    var lit = false;

    for (pins.pins) |pin| {
        const found = find(known, pin) orelse find(in_content, pin) orelse continue;
        const here = if (std.mem.startsWith(u8, found.page, "section/"))
            std.mem.eql(u8, found.page, in_page) and std.mem.eql(u8, found.plugin, in.?.plugin)
        else
            in == null and chrome.under(path, found.href);

        const Icon = @FieldType(RailEntry, "icon");
        const picked = @import("plugin_icons.zig").pick(Icon, session, found.icon, .package);

        lit = lit or here;
        try shown.append(session.arena, .{
            .href = found.href,
            .label = found.label,
            .icon = picked.icon,
            .custom_icon = picked.custom_icon,
            .active = here,
        });
    }

    const View = admin.views.RailEntries;
    const node = try admin.render.view(session.arena, View, .{
        .entries = shown.items,
    });

    return .{
        .node = node,
        .lit = lit,
    };
}

fn find(listed: []const Destination, pin: rail.Pinned) ?Destination {
    std.debug.assert(pin.page.len > 0);

    for (listed) |destination| {
        const same = std.mem.eql(u8, destination.plugin, pin.plugin) and
            std.mem.eql(u8, destination.page, pin.page);

        if (same) {
            return destination;
        }
    }

    return null;
}

fn mark_pinned(session: *const Session, listed: []Destination) Error!void {
    std.debug.assert(session.signed_in());

    if (listed.len == 0) {
        return;
    }

    var reading = session.*;
    const pins = registry.SDK.dispatch(&reading.ctx, rail.List, .{}) catch return;

    for (listed) |*destination| {
        const pin = pinned_in(pins.pins, destination.*);

        destination.pinned = pin != null;
        destination.shared = if (pin) |found| found.shared else false;
    }
}

fn pinned_in(pins: []const rail.Pinned, destination: Destination) ?rail.Pinned {
    std.debug.assert(destination.page.len > 0);

    for (pins) |pin| {
        const same = std.mem.eql(u8, destination.plugin, pin.plugin) and
            std.mem.eql(u8, destination.page, pin.page);

        if (same) {
            return pin;
        }
    }

    return null;
}

fn sees(session: *const Session, who: model.admin_pages.Who) bool {
    std.debug.assert(session.signed_in());

    return switch (who) {
        .everyone => true,
        .secrets => registry.SDK.may(&session.ctx, secret.Set),
        .providers => registry.SDK.may(&session.ctx, @import("../../operations/provider.zig").Set),
        .structure => registry.SDK.may(&session.ctx, types.Create),
        .update => registry.SDK.may(&session.ctx, update.Status),
    };
}

fn append_settings_sections(
    session: *const Session,
    listed: *std.ArrayList(Destination),
) Error!void {
    std.debug.assert(session.signed_in());

    var reading = session.*;
    const page_size = @import("../../sdk/operation.zig").page_limit_max;
    var offset: u32 = 0;

    // Every type a page at a time; only the settings ones are kept.
    while (true) : (offset += page_size) {
        const scratch = try reading.ctx.scratch();
        const begun = scratch.mark();
        defer scratch.rewind(begun);

        var paged = reading.ctx;

        paged.arena = scratch.allocator();

        const all = registry.SDK.dispatch(&paged, types.List, .{
            .offset = offset,
            .limit = page_size,
        }) catch return;

        for (all.types) |summary| {
            if (summary.kind != .settings or summary.menu_hidden) {
                continue;
            }

            const page = try std.fmt.allocPrint(session.arena, "settings/{s}", .{summary.handle});

            try listed.append(session.arena, .{
                .plugin = "",
                .page = page,
                .label = try session.arena.dupe(u8, summary.name),
                .icon = "file",
                .href = try std.fmt.allocPrint(session.arena, "/admin/{s}", .{page}),
                .group = .apps,
                .app = try session.arena.dupe(u8, summary.app),
            });
        }

        if (all.types.len < page_size) {
            return;
        }
    }
}
