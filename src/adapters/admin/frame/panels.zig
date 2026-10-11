//! Plugins' boxes on edit forms: compiled-in plugins' from the build, installed ones' from
//! their manifests, in the same shape. A panel shows on records of its type to whoever may
//! call the read that draws it; an installed plugin's panel drawn by an operation not its
//! own is never found.
const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const model = @import("../../../model/sandboxed_plugin.zig");

const Session = admin.Session;

pub const panels_max: u32 = 32;

pub const Panel = struct {
    plugin: []const u8,
    type: []const u8,
    label: []const u8,
    operation: []const u8,
};

/// Every panel the viewer may see on a record of `handle`, compiled-in plugins' first.
pub fn for_type(session: *const Session, handle: []const u8) admin.Error![]const Panel {
    std.debug.assert(session.signed_in());
    std.debug.assert(handle.len > 0);

    var shown: std.ArrayList(Panel) = .empty;

    inline for (registry.panels) |owned| {
        const fits = std.mem.eql(u8, owned.panel.type, handle);

        if (fits and registry.SDK.may(&session.ctx, owned.panel.operation)) {
            try shown.append(session.arena, .{
                .plugin = owned.plugin,
                .type = owned.panel.type,
                .label = owned.panel.label,
                .operation = owned.panel.operation.name,
            });
        }
    }

    const sandboxed = session.ctx.sandboxed_plugins orelse return shown.items;

    for (sandboxed.manifests()) |manifest| {
        for (manifest.panels) |panel| {
            if (shown.items.len == panels_max) {
                break;
            }

            const fits = std.mem.eql(u8, panel.type, handle);
            const may = registry.SDK.may_named(&session.ctx, panel.operation);

            if (fits and sound(manifest, panel) and may) {
                try shown.append(session.arena, .{
                    .plugin = manifest.name,
                    .type = panel.type,
                    .label = panel.label,
                    .operation = panel.operation,
                });
            }
        }
    }

    return shown.items;
}

/// The panel `plugin` draws with `operation` on records of `handle`, when the viewer may
/// see it.
pub fn find(
    session: *const Session,
    plugin: []const u8,
    operation: []const u8,
    handle: []const u8,
) admin.Error!?Panel {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(operation.len > 0);

    for (try for_type(session, handle)) |panel| {
        const same = std.mem.eql(u8, panel.plugin, plugin) and
            std.mem.eql(u8, panel.operation, operation);

        if (same) {
            return panel;
        }
    }

    return null;
}

/// Whether `plugin` has a panel at all, for whoever may see it: what lets its frame ask for
/// a GROQ read.
pub fn any_of(session: *const Session, plugin: []const u8) bool {
    std.debug.assert(plugin.len > 0);

    inline for (registry.panels) |owned| {
        const own = std.mem.eql(u8, owned.plugin, plugin);

        if (own and registry.SDK.may(&session.ctx, owned.panel.operation)) {
            return true;
        }
    }

    const sandboxed = session.ctx.sandboxed_plugins orelse return false;

    for (sandboxed.manifests()) |manifest| {
        if (!std.mem.eql(u8, manifest.name, plugin)) {
            continue;
        }

        for (manifest.panels) |panel| {
            if (sound(manifest, panel) and registry.SDK.may_named(&session.ctx, panel.operation)) {
                return true;
            }
        }
    }

    return false;
}

/// An installed plugin's panel names a type and a label and is drawn by one of its reads.
fn sound(manifest: model.Manifest, panel: model.Panel) bool {
    std.debug.assert(manifest.name.len > 0);

    if (panel.type.len == 0 or panel.label.len == 0) {
        return false;
    }

    for (manifest.operations) |operation| {
        if (std.mem.eql(u8, operation.name, panel.operation)) {
            return operation.kind == .read;
        }
    }

    return false;
}

test "an installed plugin's panel is drawn by one of its own reads" {
    const manifest: model.Manifest = .{
        .name = "stock",
        .version = "0.1.0",
        .summary = "Stock",
        .operations = &.{
            .{
                .name = "stock.panel",
                .kind = .read,
                .description = "Draws",
            },
            .{
                .name = "stock.set",
                .kind = .write,
                .description = "Sets",
            },
        },
    };
    const good: model.Panel = .{
        .type = "product",
        .label = "Stock",
        .operation = "stock.panel",
    };
    var writes = good;
    var foreign = good;

    writes.operation = "stock.set";
    foreign.operation = "record.get";

    try std.testing.expect(sound(manifest, good));
    try std.testing.expect(!sound(manifest, writes));
    try std.testing.expect(!sound(manifest, foreign));
}
