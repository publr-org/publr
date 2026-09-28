//! The Settings sidebar: the system's settings and the users first, then every settings
//! definition as a value-editing destination. `current` is the fixed page or the handle shown.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const types = @import("../../operations/content_type.zig");

pub fn node(session: *admin.Session, current: []const u8) admin.Error!admin.render.Node {
    std.debug.assert(session.signed_in());
    const listed = registry.SDK.dispatch(
        &session.ctx,
        types.List,
        .{},
    ) catch return error.OutOfMemory;
    var items: std.ArrayList(admin.views.SettingsNav.SectionsItem) = .empty;

    for (listed.types) |summary| {
        if (summary.kind != .settings) continue;
        try items.append(session.arena, .{
            .label = summary.name,
            .href = try std.fmt.allocPrint(session.arena, "/admin/settings/{s}", .{summary.handle}),
            .active = std.mem.eql(u8, current, summary.handle),
        });
    }

    return admin.render.view(session.arena, admin.views.SettingsNav, .{
        .system_active = std.mem.eql(u8, current, "system"),
        .users_active = std.mem.eql(u8, current, "users"),
        .sections = items.items,
    });
}
