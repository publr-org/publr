//! The admin's own pages under Settings, in the order its sidebar lists them: each one a
//! person may pin to their rail, named by its address below `/admin/`.

const std = @import("std");

/// Who sees the page, beyond being signed in.
pub const Who = enum { everyone, secrets, structure, update };

/// The groups Settings lists its pages under, in order.
pub const Group = enum {
    general,
    site,
    plugins,
    data,
    apps,

    pub fn label(group: Group) []const u8 {
        return groups[@intFromEnum(group)].label;
    }
};

const Named = struct {
    label: []const u8,
};

const groups = [_]Named{
    .{
        .label = "General",
    },
    .{
        .label = "Site",
    },
    .{
        .label = "Plugins",
    },
    .{
        .label = "Data",
    },
    .{
        .label = "Apps",
    },
};

pub const Page = struct {
    /// Its name for a pin, and its address below `/admin/`.
    page: []const u8,
    label: []const u8,
    icon: []const u8,
    who: Who = .everyone,
    group: Group,
};

pub const all = [_]Page{
    .{
        .page = "settings/system",
        .label = "System settings",
        .icon = "settings",
        .group = .general,
    },
    .{
        .page = "settings/users",
        .label = "Users",
        .icon = "users",
        .group = .general,
    },
    .{
        .page = "settings/devices",
        .label = "Devices",
        .icon = "device-desktop",
        .group = .general,
    },
    .{
        .page = "settings/ai",
        .label = "AI",
        .icon = "sparkles",
        .who = .secrets,
        .group = .general,
    },
    .{
        .page = "settings/secrets",
        .label = "Secrets",
        .icon = "lock",
        .who = .secrets,
        .group = .general,
    },
    .{
        .page = "structure",
        .label = "Structure",
        .icon = "components",
        .who = .structure,
        .group = .site,
    },
    .{
        .page = "health",
        .label = "Site Health",
        .icon = "alert-hexagon",
        .who = .structure,
        .group = .site,
    },
    .{
        .page = "settings/updates",
        .label = "Updates",
        .icon = "sync",
        .who = .update,
        .group = .site,
    },
    .{
        .page = "settings/plugins",
        .label = "Plugins",
        .icon = "package",
        .group = .plugins,
    },
    .{
        .page = "trash",
        .label = "Trash",
        .icon = "trash",
        .group = .data,
    },
    .{
        .page = "removals",
        .label = "Removals",
        .icon = "alert-triangle",
        .group = .data,
    },
    .{
        .page = "settings/apps",
        .label = "Apps",
        .icon = "layout-grid",
        .group = .apps,
    },
};

pub fn find(page: []const u8) ?Page {
    std.debug.assert(all.len > 0);
    std.debug.assert(page.len <= 1 << 16);

    for (all) |one| {
        if (std.mem.eql(u8, one.page, page)) {
            return one;
        }
    }

    return null;
}

/// A settings section's page: `settings/<handle>`, the handle alone when it is one.
pub fn settings_handle(page: []const u8) ?[]const u8 {
    std.debug.assert(page.len <= 1 << 16);

    const prefix = "settings/";

    if (!std.mem.startsWith(u8, page, prefix) or find(page) != null) {
        return null;
    }

    const handle = page[prefix.len..];

    return if (handle.len > 0 and std.mem.indexOfScalar(u8, handle, '/') == null) handle else null;
}

/// A plugin section's page: `section/<handle>`, its first type, the handle alone.
pub fn section_handle(page: []const u8) ?[]const u8 {
    std.debug.assert(page.len <= 1 << 16);

    const prefix = "section/";

    if (!std.mem.startsWith(u8, page, prefix) or page.len == prefix.len) {
        return null;
    }

    return page[prefix.len..];
}

test "core pages by name, settings sections and plugin sections by their handle" {
    try std.testing.expectEqualStrings("Users", find("settings/users").?.label);
    try std.testing.expect(find("settings/nope") == null);
    try std.testing.expectEqualStrings("shipping", settings_handle("settings/shipping").?);
    try std.testing.expect(settings_handle("settings/users") == null);
    try std.testing.expect(settings_handle("settings/a/b") == null);
    try std.testing.expectEqualStrings("course", section_handle("section/course").?);
    try std.testing.expect(section_handle("section/") == null);
}
