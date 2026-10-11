//! Plugins' sections: parts of the admin of their own on the rail, each some of its plugin's
//! record types, listed and edited as the admin's content is and left out of the Content
//! sidebar. Compiled-in plugins' from the build, installed ones' from their manifests; a
//! section shows only the types its plugin owns (the database says whose a type is) that
//! the viewer sees, and is left out when that is none.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const types = @import("../../operations/content_type.zig");
const admin_slots = @import("../../sdk/plugin/admin_slots.zig");
const filters = @import("content/filters.zig");
const nav = @import("nav.zig");

const Session = admin.Session;
const Error = admin.Error;
const Summary = types.Summary;

pub const sections_max: u32 = 32;

pub const Type = struct {
    handle: []const u8,
    label: []const u8,
    href: []const u8,
    columns: []const []const u8,
};

pub const Section = struct {
    plugin: []const u8,
    label: []const u8,
    icon: []const u8,
    types: []const Type,

    /// Where it opens: its first type's list.
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

const Declared = struct {
    label: []const u8,
    icon: []const u8,
    types: []const model.sandboxed_plugin.SectionType,
};

/// Every section the viewer sees, compiled-in plugins' first, in name order.
pub fn all(session: *const Session) Error![]const Section {
    std.debug.assert(session.signed_in());

    if (registry.sections.len == 0 and manifests_with_sections(session) == 0) {
        return &.{};
    }

    var shown: std.ArrayList(Section) = .empty;

    inline for (registry.sections) |registered| {
        const declared = comptime declared_of(registered.section);

        if (try resolve(session, registered.plugin, declared)) |section| {
            try shown.append(session.arena, section);
        }
    }

    const sandboxed = session.ctx.sandboxed_plugins orelse return shown.items;

    for (sandboxed.manifests()) |manifest| {
        for (manifest.sections) |section| {
            if (shown.items.len == sections_max) {
                break;
            }

            const declared: Declared = .{
                .label = section.label,
                .icon = section.icon,
                .types = section.types,
            };

            if (try resolve(session, manifest.name, declared)) |resolved| {
                try shown.append(session.arena, resolved);
            }
        }
    }

    return shown.items;
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

/// The section's sidebar, the type the page shows lit.
pub fn sidebar_of(
    session: *const Session,
    section: Section,
    content: nav.Current,
) Error!admin.render.Node {
    std.debug.assert(session.signed_in());
    std.debug.assert(section.types.len > 0);

    const Item = admin.views.SectionNav.TypesItem;
    const items = try session.arena.alloc(Item, section.types.len);
    const lit = if (content.filters.types.len == 1) content.filters.types[0] else "";

    for (section.types, items) |one, *item| {
        const active = std.mem.eql(u8, one.handle, lit);

        item.* = .{
            .label = one.label,
            .href = one.href,
            .active = active,
        };
    }

    return admin.render.view(session.arena, admin.views.SectionNav, .{
        .types = items,
    });
}

pub fn heading_of(session: *const Session, section: Section) Error!admin.render.Node {
    std.debug.assert(session.signed_in());

    const Heading = admin.views.SectionHeading;
    const icon = std.meta.stringToEnum(@FieldType(Heading.Props, "icon"), section.icon);

    return admin.render.view(session.arena, Heading, .{
        .href = section.href(),
        .label = section.label,
        .icon = icon orelse .package,
    });
}

fn declared_of(comptime section: admin_slots.Section) Declared {
    comptime {
        std.debug.assert(section.types.len > 0);

        var listed: []const model.sandboxed_plugin.SectionType = &.{};

        for (section.types) |one| {
            listed = listed ++ &[_]model.sandboxed_plugin.SectionType{.{
                .handle = one.handle,
                .columns = one.columns,
            }};
        }

        return .{
            .label = section.label,
            .icon = section.icon,
            .types = listed,
        };
    }
}

/// The section as the viewer sees it: the types its plugin owns among those listed.
fn resolve(
    session: *const Session,
    plugin: []const u8,
    declared: Declared,
) Error!?Section {
    std.debug.assert(plugin.len > 0);

    if (declared.label.len == 0 or declared.types.len > admin_slots.section_types_max) {
        return null;
    }

    var shown: std.ArrayList(Type) = .empty;

    for (declared.types) |one| {
        const summary = try owned(session, plugin, one.handle) orelse continue;
        const filter: model.view.Filters = .{
            .types = &.{summary.handle},
            .type_view = true,
        };

        try shown.append(session.arena, .{
            .handle = summary.handle,
            .label = summary.name,
            .href = try filters.format(session.arena, filter, null),
            .columns = one.columns[0..@min(one.columns.len, admin_slots.columns_max)],
        });
    }

    if (shown.items.len == 0) {
        return null;
    }

    return .{
        .plugin = plugin,
        .label = declared.label,
        .icon = declared.icon,
        .types = shown.items,
    };
}

/// The plugin's record type of this handle, by its own lookup; null when it has none.
fn owned(session: *const Session, plugin: []const u8, handle: []const u8) Error!?Owned {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(handle.len > 0);

    var looking = session.*;
    const got = registry.SDK.dispatch(&looking.ctx, types.Get, .{
        .type = handle,
    }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else null;
    const def = got.definition;
    const ours = std.mem.eql(u8, def.owner, plugin) and def.kind == .record;

    if (!ours) {
        return null;
    }

    return .{
        .handle = def.handle,
        .name = def.name,
    };
}

const Owned = struct {
    handle: []const u8,
    name: []const u8,
};

fn manifests_with_sections(session: *const Session) u32 {
    std.debug.assert(session.signed_in());

    const sandboxed = session.ctx.sandboxed_plugins orelse return 0;
    var count: u32 = 0;

    for (sandboxed.manifests()) |manifest| {
        count += @intCast(manifest.sections.len);
    }

    return count;
}
