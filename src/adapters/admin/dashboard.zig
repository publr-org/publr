const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const plugin = @import("../../operations/plugin.zig");

const views = admin.views;
const Shortcut = views.Dashboard.ShortcutsItem;

pub fn shortcuts_of(session: *admin.Session) admin.Error![]const Shortcut {
    std.debug.assert(session.signed_in());
    std.debug.assert(session.identity.email.len > 0);

    var shortcuts: std.ArrayList(Shortcut) = .empty;

    if (!registry.SDK.may(&session.ctx, plugin.List)) {
        return shortcuts.items;
    }

    const listed = registry.SDK.dispatch(&session.ctx, plugin.List, .{}) catch {
        return error.OutOfMemory;
    };
    var pending: u64 = 0;

    for (listed.plugins) |row| {
        pending += row.pending;
    }

    if (pending > 0) {
        try shortcuts.append(session.arena, .{
            .label = "Approve plugin requests",
            .count = try std.fmt.allocPrint(session.arena, "{d}", .{pending}),
            .href = "/admin/settings/plugins",
        });
    }

    return shortcuts.items;
}
