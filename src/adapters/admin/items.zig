//! The entries plugins add to the top bar:
//! compiled-in plugins' from the build, installed ones' from their manifests, each shown
//! to whoever may call its operation and leading only to one of the plugin's pages. An
//! installed plugin's entry naming an operation not its own
//! is never shown.
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

    inline for (registry.top_bar) |owned| {
        if (registry.SDK.may(&session.ctx, owned.item.operation)) {
            try entries.append(session.arena, .{
                .plugin = owned.plugin,
                .label = owned.item.label,
                .icon = owned.item.icon,
                .href = try href_of(session, owned.plugin, owned.item.page),
                .count = if (owned.item.count) |Count| Count.name else "",
            });
        }
    }

    const sandboxed = session.ctx.sandboxed_plugins orelse return entries.items;

    for (sandboxed.manifests()) |manifest| {
        const declared = manifest.top_bar;

        for (declared) |item| {
            if (entries.items.len == entries_max) {
                break;
            }

            if (sound(manifest, item) and registry.SDK.may_named(&session.ctx, item.operation)) {
                try entries.append(session.arena, .{
                    .plugin = manifest.name,
                    .label = item.label,
                    .icon = item.icon,
                    .href = try href_of(session, manifest.name, item.page),
                    .count = item.count,
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

/// An installed plugin's entry: a label, its own operations, and a page of its own.
fn sound(manifest: model.Manifest, item: model.Item) bool {
    std.debug.assert(manifest.name.len > 0);

    const leads = item.page.len > 0 and has_page(manifest, item.page);
    const counted = item.count.len == 0 or own_kind(manifest, item.count) == .read;

    return item.label.len > 0 and leads and counted and own_kind(manifest, item.operation) != null;
}

fn has_page(manifest: model.Manifest, path: []const u8) bool {
    std.debug.assert(path.len > 0);

    for (manifest.pages) |page| {
        if (std.mem.eql(u8, page.path, path)) {
            return true;
        }
    }

    return false;
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

test "an installed plugin's entry leads into the admin through its own operations" {
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
        .pages = &.{.{
            .path = "entries",
            .label = "Notes",
            .icon = "file",
            .operation = "notes.list",
        }},
    };
    const good: model.Item = .{
        .label = "Notes",
        .icon = "file",
        .page = "entries",
        .operation = "notes.list",
        .count = "notes.count",
    };
    var foreign = good;
    var no_page = good;

    foreign.operation = "user.list";
    no_page.page = "missing";

    try std.testing.expect(sound(manifest, good));
    try std.testing.expect(!sound(manifest, foreign));
    try std.testing.expect(!sound(manifest, no_page));
}
