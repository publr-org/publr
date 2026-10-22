//! The Settings sidebar: every page under Settings the viewer may see, the one the address
//! is under lit, each with its pin (`destinations.zig` lists them).
const std = @import("std");
const admin = @import("../admin.zig");
const chrome = @import("chrome.zig");
const destinations = @import("destinations.zig");
const model = @import("../../model.zig");

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

    for (listed, pages, 0..) |destination, *page, index| {
        const own = destination.plugin.len == 0;
        const previous: ?destinations.Destination = if (index == 0) null else listed[index - 1];
        const structure = own and std.mem.eql(u8, destination.page, "structure");
        const health = own and std.mem.eql(u8, destination.page, "health");

        page.* = .{
            .label = try session.declared(destination.label),
            .href = destination.href,
            .icon = std.meta.stringToEnum(@FieldType(Page, "icon"), destination.icon) orelse
                .package,
            .custom_icon = "",
            .active = if (structure) in_structure(path) else chrome.under(path, destination.href),
            .plugin = destination.plugin,
            .page = destination.page,
            .pinned = destination.pinned,
            .shared = destination.shared,
            .count = if (health) try health_count(session) else "",
            .group = try group_of(session, destination, previous),
            .heading = try heading_of(session, destination, previous),
        };
    }

    return admin.render.view(session.arena, admin.views.SettingsNav, .{
        .pages = pages,
        .csrf = session.csrf_token(),
        .back = path,
        .admin = session.ctx.caller.holds("admin"),
    });
}

/// The group's name over its first page; empty for the rest.
fn group_of(
    session: *admin.Session,
    destination: destinations.Destination,
    previous: ?destinations.Destination,
) admin.Error![]const u8 {
    std.debug.assert(destination.page.len > 0);
    std.debug.assert(previous == null or @intFromEnum(previous.?.group) <=
        @intFromEnum(destination.group));

    if (previous != null and previous.?.group == destination.group) {
        return "";
    }

    return session.declared(destination.group.label());
}

/// Over the first settings section of each app, the app's name ("Global" for the project's
/// own); empty everywhere else.
fn heading_of(
    session: *admin.Session,
    destination: destinations.Destination,
    previous: ?destinations.Destination,
) admin.Error![]const u8 {
    std.debug.assert(destination.page.len > 0);
    std.debug.assert(destination.app.len == 0 or destination.group == .apps);

    const section = model.admin_pages.settings_handle(destination.page) != null and
        destination.plugin.len == 0 and destination.group == .apps;

    if (!section) {
        return "";
    }

    if (previous) |before| {
        const before_section = model.admin_pages.settings_handle(before.page) != null and
            before.group == .apps;

        if (before_section and std.mem.eql(u8, before.app, destination.app)) {
            return "";
        }
    }

    if (destination.app.len == 0) {
        return session.translated("Global", .{});
    }

    const app = session.project.find(destination.app) orelse return destination.app;

    return app.spec.label;
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
