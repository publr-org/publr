//! The top bar's items: the entries plugins add (`items.zig`), drawn by the admin, then which
//! app the admin shows where the project has apps, with what plugins join to it
//! (`app_picker_segment`); where it has none, those segments stand on their own.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const items = @import("items.zig");

const Session = admin.Session;
const Node = admin.render.Node;
const items_max: u32 = 16;

/// What the top bar shows this viewer; null when nothing. An item that fails to render is
/// left out and logged: the page stays up.
pub fn of(session: *const Session) ?Node {
    std.debug.assert(session.signed_in());
    comptime std.debug.assert(2 + registry.app_picker_segment.len <= items_max);

    var shown: [items_max]Node = undefined;
    var count: u32 = 0;
    var reading = session.*;

    if (@import("variant.zig").switcher(&reading)) |node| {
        shown[count] = node;
        count += 1;
    }

    for (entries_of(session)) |node| {
        if (count + 2 + registry.app_picker_segment.len >= items_max) {
            break;
        }

        shown[count] = node;
        count += 1;
    }

    const picker = session.project.apps.len > 0;
    var segments: [items_max]Node = undefined;
    const joined = segments_of(session, picker, &segments);

    if (picker) {
        const after = if (joined.len > 0)
            admin.render.all(session.arena, joined) catch null
        else
            null;

        if (admin.app_scope.switcher(session, after)) |node| {
            shown[count] = node;
            count += 1;
        }
    } else {
        for (joined) |segment| {
            shown[count] = segment;
            count += 1;
        }
    }

    if (count == 0) {
        return null;
    }

    const kept = session.arena.dupe(Node, shown[0..count]) catch return null;

    return admin.render.all(session.arena, kept) catch null;
}

const Entry = admin.views.TopBarEntry;

/// The plugins' entries, each drawn by the admin; an entry that fails is left out and
/// logged. Counts are plugins' reads, so they run on a copy of the session of their own.
fn entries_of(session: *const Session) []const Node {
    std.debug.assert(session.signed_in());

    const listed = items.of(session, .top_bar) catch return &.{};
    const reading = session.arena.create(Session) catch return &.{};
    var nodes: std.ArrayList(Node) = .empty;

    reading.* = session.*;

    for (listed) |entry| {
        const icon = std.meta.stringToEnum(@FieldType(Entry.Props, "icon"), entry.icon);
        const node = admin.render.view(session.arena, Entry, .{
            .href = entry.href,
            .label = entry.label,
            .icon = icon orelse .package,
            .count = items.count_of(reading, entry),
        }) catch continue;

        nodes.append(session.arena, node) catch return nodes.items;
    }

    return nodes.items;
}

/// What plugins join to the app picker (`attached`), or show alone where there is none; a
/// segment that fails to render is left out and logged.
fn segments_of(session: *const Session, attached: bool, into: []Node) []const Node {
    std.debug.assert(session.signed_in());
    std.debug.assert(into.len >= registry.app_picker_segment.len);

    var count: u32 = 0;

    inline for (registry.app_picker_segment) |Plugin| {
        const segment = Plugin.app_picker_segment(session, attached) catch |err| blk: {
            std.log.warn("plugin {s}: app picker segment: {t}", .{ Plugin.manifest.name, err });
            break :blk null;
        };

        if (segment) |node| {
            into[count] = node;
            count += 1;
        }
    }

    return session.arena.dupe(Node, into[0..count]) catch &.{};
}
