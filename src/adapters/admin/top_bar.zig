//! The top bar's items: each compiled-in plugin's, in name order, then which app the admin
//! shows where the project has apps.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");

const Session = admin.Session;
const Node = admin.render.Node;
const items_max: u32 = 16;

/// What the top bar shows this viewer; null when nothing. An item that fails to render is
/// left out and logged: the page stays up.
pub fn of(session: *const Session) ?Node {
    std.debug.assert(session.signed_in());
    comptime std.debug.assert(registry.top_bar.len + 1 <= items_max);

    var items: [items_max]Node = undefined;
    var count: u32 = 0;

    inline for (registry.top_bar) |Plugin| {
        const item = Plugin.top_bar(session) catch |err| blk: {
            std.log.warn("plugin {s}: top bar item: {t}", .{ Plugin.manifest.name, err });
            break :blk null;
        };

        if (item) |node| {
            items[count] = node;
            count += 1;
        }
    }

    if (admin.app_scope.switcher(session)) |node| {
        items[count] = node;
        count += 1;
    }

    if (count == 0) {
        return null;
    }

    const kept = session.arena.dupe(Node, items[0..count]) catch return null;

    return admin.render.all(session.arena, kept) catch null;
}
