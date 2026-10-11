//! The Settings sidebar: every page under Settings the viewer may see, the one the address
//! is under lit, each with its pin (`destinations.zig` lists them).
const std = @import("std");
const admin = @import("../admin.zig");
const chrome = @import("chrome.zig");
const destinations = @import("destinations.zig");

/// The addresses Structure stands for: the hub and every kind of definition under it.
const structure_paths = [_][]const u8{
    "/admin/structure",
    "/admin/types",
    "/admin/terms",
    "/admin/components",
    "/admin/custom-fields",
};

const Page = admin.views.SettingsNav.PagesItem;

pub fn node(session: *admin.Session, path: []const u8) admin.Error!admin.render.Node {
    std.debug.assert(session.signed_in());
    std.debug.assert(path.len > 0);

    const listed = try destinations.settings(session);
    const pages = try session.arena.alloc(Page, listed.len);

    for (listed, pages) |destination, *page| {
        const own = destination.plugin.len == 0;
        const structure = own and std.mem.eql(u8, destination.page, "structure");
        const health = own and std.mem.eql(u8, destination.page, "health");

        page.* = .{
            .label = try session.declared(destination.label),
            .href = destination.href,
            .icon = std.meta.stringToEnum(@FieldType(Page, "icon"), destination.icon) orelse
                .package,
            .active = if (structure) in_structure(path) else chrome.under(path, destination.href),
            .plugin = destination.plugin,
            .page = destination.page,
            .pinned = destination.pinned,
            .count = if (health) try health_count(session) else "",
        };
    }

    return admin.render.view(session.arena, admin.views.SettingsNav, .{
        .pages = pages,
        .csrf = session.csrf_token(),
        .back = path,
    });
}

/// Site Health's cases not kept as they are, as the badge shows them; empty for none.
fn health_count(session: *admin.Session) admin.Error![]const u8 {
    std.debug.assert(session.signed_in());

    const registry = @import("../../server/registry.zig");
    const health = @import("../../operations/health.zig");
    const counted = registry.SDK.dispatch(&session.ctx, health.Count, .{}) catch return "";

    if (counted.count == 0) {
        return "";
    }

    return std.fmt.allocPrint(session.arena, "{d}", .{counted.count}) catch error.OutOfMemory;
}

fn in_structure(path: []const u8) bool {
    std.debug.assert(path.len > 0);
    std.debug.assert(structure_paths.len > 0);

    for (structure_paths) |prefix| {
        if (chrome.under(path, prefix)) {
            return true;
        }
    }

    return false;
}
