//! The entries plugins add to the top bar: their pages that say `.top_bar`, compiled-in
//! plugins' from the build, installed ones' from their manifests, each shown to whoever may
//! see the page. An installed plugin's page naming an operation not its own is never shown.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model/sandboxed_plugin.zig");
const frame = @import("frame.zig");

const Session = admin.Session;

pub const entries_max: u32 = 32;

pub const Entry = struct {
    plugin: []const u8,
    label: []const u8,
    icon: []const u8,
    href: []const u8,
    /// The plugin's read answering `count`; empty for none.
    count: []const u8,
};

/// The top bar entries the viewer may see, compiled-in plugins' first, in name order.
pub fn of(session: *const Session) admin.Error![]const Entry {
    std.debug.assert(session.signed_in());

    var entries: std.ArrayList(Entry) = .empty;

    inline for (registry.pages) |owned| {
        const page = owned.page;
        const shown = comptime page.top_bar != null;

        if (shown and registry.SDK.may(&session.ctx, comptime page.gate())) {
            try entries.append(session.arena, .{
                .plugin = owned.plugin,
                .label = page.label,
                .icon = page.icon,
                .href = try href_of(session, owned.plugin, page.path),
                .count = if (comptime page.top_bar.?.count) |Count| Count.name else "",
            });
        }
    }

    const sandboxed = session.ctx.sandboxed_plugins orelse return entries.items;

    for (sandboxed.manifests()) |manifest| {
        for (manifest.pages) |page| {
            if (entries.items.len == entries_max) {
                break;
            }

            const shown = page.top_bar orelse continue;
            const gate = gate_of(page);

            if (sound(manifest, page) and registry.SDK.may_named(&session.ctx, gate)) {
                try entries.append(session.arena, .{
                    .plugin = manifest.name,
                    .label = page.label,
                    .icon = page.icon,
                    .href = try href_of(session, manifest.name, page.path),
                    .count = shown.count,
                });
            }
        }
    }

    return entries.items;
}

/// What an entry's count read answers, as text; empty when it has none or the read fails.
pub fn count_of(session: *Session, entry: Entry) []const u8 {
    std.debug.assert(entry.label.len > 0);

    if (entry.count.len == 0) {
        return "";
    }

    const output = registry.SDK.call_json(&session.ctx, entry.count, "{}") catch |err| {
        std.log.warn("plugin {s}: count {s}: {t}", .{ entry.plugin, entry.count, err });
        return "";
    };
    const Counted = struct {
        count: i64,
    };
    const counted = std.json.parseFromSliceLeaky(Counted, session.arena, output, .{
        .ignore_unknown_fields = true,
    }) catch return "";

    return std.fmt.allocPrint(session.arena, "{d}", .{counted.count}) catch "";
}

fn href_of(
    session: *const Session,
    plugin: []const u8,
    page: []const u8,
) admin.Error![]const u8 {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(page.len > 0);

    return std.fmt.allocPrint(session.arena, "{s}/{s}/{s}", .{ frame.prefix, plugin, page });
}

/// What decides who sees an installed plugin's page: the drawing read, or the form's.
fn gate_of(page: model.Page) []const u8 {
    return if (page.operation.len > 0) page.operation else page.read;
}

/// An installed plugin's page in the top bar: a label, its own operations, not tabbed.
fn sound(manifest: model.Manifest, page: model.Page) bool {
    std.debug.assert(manifest.name.len > 0);

    const shown = page.top_bar orelse return false;
    const counted = shown.count.len == 0 or own_kind(manifest, shown.count) == .read;
    const gate = gate_of(page);
    const own = gate.len > 0 and own_kind(manifest, gate) != null;

    return page.label.len > 0 and !page.tabs and counted and own;
}

fn own_kind(manifest: model.Manifest, name: []const u8) ?model.Kind {
    std.debug.assert(manifest.name.len > 0);

    for (manifest.operations) |operation| {
        if (std.mem.eql(u8, operation.name, name)) {
            return operation.kind;
        }
    }

    return null;
}

test "an installed plugin's page is in the top bar through its own operations" {
    const good: model.Page = .{
        .path = "entries",
        .label = "Notes",
        .icon = "file",
        .operation = "notes.list",
        .top_bar = .{
            .count = "notes.count",
        },
    };
    const manifest: model.Manifest = .{
        .name = "notes",
        .version = "0.1.0",
        .summary = "Notes",
        .operations = &.{
            .{
                .name = "notes.list",
                .kind = .read,
                .description = "List",
            },
            .{
                .name = "notes.count",
                .kind = .read,
                .description = "Count",
            },
        },
        .pages = &.{good},
    };
    var foreign = good;
    var not_shown = good;

    foreign.operation = "user.list";
    not_shown.top_bar = null;

    try std.testing.expect(sound(manifest, good));
    try std.testing.expect(!sound(manifest, foreign));
    try std.testing.expect(!sound(manifest, not_shown));
}
