//! Plugins' own pages: compiled-in plugins' from the build, installed ones' from their
//! manifests, in the same shape. A page is listed and drawn for whoever may call the read
//! that draws it; an installed plugin's page naming an operation that is not its own is
//! never found.
const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const admin_slots = @import("../../../sdk/plugin/admin_slots.zig");

const Session = admin.Session;

pub const pages_max: u32 = 64;
pub const operations_max: u32 = 256;

pub const Page = struct {
    plugin: []const u8,
    path: []const u8,
    label: []const u8,
    icon: []const u8,
    /// The read that draws it in the frame; empty for a form by declaration.
    operation: []const u8,
    /// A form by declaration: the read that fills it, the write that saves it, the fields
    /// drawn as several lines.
    read: []const u8 = "",
    save: []const u8 = "",
    multiline: []const []const u8 = &.{},

    pub fn declared(page: Page) bool {
        std.debug.assert(page.path.len > 0);

        return page.save.len > 0;
    }

    /// The operation that decides who sees it.
    pub fn gate(page: Page) []const u8 {
        std.debug.assert(page.operation.len > 0 or page.read.len > 0);

        return if (page.operation.len > 0) page.operation else page.read;
    }
};

/// Every page the viewer may open, compiled-in plugins' first, in name order.
pub fn all(session: *const Session) admin.Error![]const Page {
    std.debug.assert(session.signed_in());
    comptime std.debug.assert(registry.pages.len <= pages_max);

    var list: std.ArrayList(Page) = .empty;

    inline for (registry.pages) |owned| {
        if (registry.SDK.may(&session.ctx, comptime owned.page.gate())) {
            try list.append(session.arena, comptime native(owned));
        }
    }

    for (manifests_of(session)) |manifest| {
        for (manifest.pages) |page| {
            if (list.items.len == pages_max) {
                break;
            }

            const shown: Page = .{
                .plugin = manifest.name,
                .path = page.path,
                .label = page.label,
                .icon = page.icon,
                .operation = page.operation,
                .read = page.read,
                .save = page.save,
                .multiline = page.multiline,
            };

            if (sound(manifest, page) and registry.SDK.may_named(&session.ctx, shown.gate())) {
                try list.append(session.arena, shown);
            }
        }
    }

    return list.items;
}

fn native(comptime owned: @import("../../../sdk/plugin.zig").OwnedPage) Page {
    comptime {
        const page = owned.page;

        std.debug.assert(owned.plugin.len > 0);

        return .{
            .plugin = owned.plugin,
            .path = page.path,
            .label = page.label,
            .icon = page.icon,
            .operation = if (page.operation) |Operation| Operation.name else "",
            .read = if (page.form) |form| form.read.name else "",
            .save = if (page.form) |form| form.save.name else "",
            .multiline = if (page.form) |form| form.multiline else &.{},
        };
    }
}

/// The page at `path` of `plugin`, when the viewer may open it.
pub fn find(session: *const Session, plugin: []const u8, path: []const u8) admin.Error!?Page {
    std.debug.assert(session.signed_in());
    std.debug.assert(plugin.len > 0);

    for (try all(session)) |page| {
        if (std.mem.eql(u8, page.plugin, plugin) and std.mem.eql(u8, page.path, path)) {
            return page;
        }
    }

    return null;
}

/// The operations of `plugin`'s own: the only ones its frame may ask the admin to run.
pub fn operations_of(session: *const Session, plugin: []const u8) admin.Error![]const []const u8 {
    std.debug.assert(session.signed_in());
    std.debug.assert(plugin.len > 0);

    var list: std.ArrayList([]const u8) = .empty;
    const owners = registry.registry.operation_owners;

    inline for (registry.SDK.operations, 0..) |Operation, index| {
        if (std.mem.eql(u8, owners[index], plugin)) {
            try list.append(session.arena, Operation.name);
        }
    }

    for (manifests_of(session)) |manifest| {
        if (!std.mem.eql(u8, manifest.name, plugin)) {
            continue;
        }

        for (manifest.operations) |operation| {
            if (list.items.len < operations_max) {
                try list.append(session.arena, operation.name);
            }
        }
    }

    return list.items;
}

const Manifest = @import("../../../sdk/sandboxed_plugins.zig").Manifest;
const ManifestPage = @import("../../../model/sandboxed_plugin.zig").Page;

fn manifests_of(session: *const Session) []const Manifest {
    std.debug.assert(session.ctx.now_ms > 0);

    const sandboxed = session.ctx.sandboxed_plugins orelse return &.{};
    const manifests = sandboxed.manifests();

    std.debug.assert(manifests.len <= @import("../../../model/sandboxed_plugin.zig")
        .sandboxed_plugins_max);

    return manifests;
}

/// A manifest's page is a page path drawn by one of the plugin's own reads, or a form
/// filled by one of its reads and saved by one of its writes.
fn sound(manifest: Manifest, page: ManifestPage) bool {
    std.debug.assert(manifest.name.len > 0);

    if (!admin_slots.is_page_path(page.path) or page.label.len == 0) {
        return false;
    }

    if (page.operation.len > 0) {
        return own_kind(manifest, page.operation) == .read and page.save.len == 0;
    }

    return own_kind(manifest, page.read) == .read and own_kind(manifest, page.save) == .write;
}

const Kind = @import("../../../model/sandboxed_plugin.zig").Kind;

fn own_kind(manifest: Manifest, name: []const u8) ?Kind {
    std.debug.assert(manifest.name.len > 0);

    for (manifest.operations) |operation| {
        if (std.mem.eql(u8, operation.name, name)) {
            return operation.kind;
        }
    }

    return null;
}

test "an installed plugin's page drawn by another's operation is not sound" {
    const own: Manifest = .{
        .name = "notes",
        .version = "0.1.0",
        .summary = "Notes",
        .operations = &.{.{
            .name = "notes.page",
            .kind = .read,
            .description = "Draws",
        }},
    };
    const page: ManifestPage = .{
        .path = "all",
        .label = "Notes",
        .icon = "file",
        .operation = "notes.page",
    };
    var borrowed = page;
    var bad_path = page;

    borrowed.operation = "user.list";
    bad_path.path = "../x";

    try std.testing.expect(sound(own, page));
    try std.testing.expect(!sound(own, borrowed));
    try std.testing.expect(!sound(own, bad_path));
}
