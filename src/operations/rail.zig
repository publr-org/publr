const std = @import("std");
const sdk = @import("../sdk.zig");
const registry = @import("../server/registry.zig");
const model = @import("../model.zig");
const store = @import("../store.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const pins = store.rail_pins;
const shared_pins = store.shared_rail_pins;
const admin_pages = model.admin_pages;

pub const namespace: sdk.operation.Namespace = .{
    .name = "rail",
    .label = "Rail pins",
    .area = .background,
    .summary = "The pages a person pins to their rail",
    .details =
    \\The rail holds Overview, Content and Media, then what the person pinned, in the order
    \\pinned. Nothing else adds to it: a plugin registers pages and sections, and people pin
    \\the ones they use. A pin names a page: a core one by its address below `/admin/`
    \\(`settings/users`, `trash`, `settings/<handle>` for a settings section), or a plugin's
    \\by the plugin and its page (a page's path, a settings page's address, or
    \\`section/<name>` for a section, named by its menu item: `products`, `section/shop`).
    \\Each person pins for themselves; administrators may also pin for everyone
    \\(`for_everyone`): those come first on every rail, and a person may hide one for
    \\themselves by unpinning it. A page someone may not see is not drawn. Signed-in
    \\callers only.
    ,
};

pub const per_user_max = pins.per_user_max;

pub const Pinned = struct {
    plugin: []const u8,
    page: []const u8,
    /// Pinned by an administrator for everyone.
    shared: bool = false,
};

pub const List = struct {
    pub const name = "rail.list";
    pub const description = "List the pages on the caller's rail, top to bottom";
    pub const details =
        \\The pins made for everyone (`shared`), less those the caller hid, then the
        \\caller's own. A pin whose page is gone (its plugin removed) stays listed and is
        \\not drawn; unpin it to drop it.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        pins: []const Pinned,
    };
    pub const example: In = .{};
    // A new account has pinned nothing; `rail pin` answers each pin as it lands.
    pub const example_out: Out = .{
        .pins = &.{},
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(@sizeOf(In) == 0);

        _ = in;

        const owner = ctx.caller.user_id() orelse return error.Denied;
        const everyone = try shared_pins.list(ctx.db, ctx.arena);
        const hidden = try pins.hidden(ctx.db, ctx.arena, owner);
        const rows = try pins.list(ctx.db, ctx.arena, owner);
        var out: std.ArrayList(Pinned) = .empty;

        for (everyone) |row| {
            if (!listed(hidden, row)) {
                out.append(ctx.arena, .{
                    .plugin = row.plugin,
                    .page = row.page,
                    .shared = true,
                }) catch return error.OutOfMemory;
            }
        }

        for (rows) |row| {
            if (!listed(everyone, row)) {
                out.append(ctx.arena, .{
                    .plugin = row.plugin,
                    .page = row.page,
                }) catch return error.OutOfMemory;
            }
        }

        return .{
            .pins = out.items,
        };
    }
};

pub const Pin = struct {
    pub const name = "rail.pin";
    pub const description = "Pin a page to the caller's rail, below the others";
    pub const details =
        \\`page` alone for a core page; `plugin` and `page` for a plugin's. Invalid unless the
        \\page exists. Pinned already, it stays where it is. Up to 16 pins. `for_everyone`
        \\pins it to everyone's rail (administrators only), up to 16.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        plugin: []const u8 = "",
        page: []const u8,
        for_everyone: bool = false,
    };
    pub const Out = Pinned;
    pub const example: In = .{
        .page = "settings/users",
    };
    pub const example_out: Out = .{
        .plugin = "",
        .page = "settings/users",
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .plugin = "The plugin whose page it is; empty for a core page",
        .page = "The page: `settings/users`, a plugin page's path, `section/<menu item>`",
        .for_everyone = "On everyone's rail (administrators only)",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const owner = ctx.caller.user_id() orelse return error.Denied;

        if (in.page.len == 0 or in.page.len > pins.page_len_max or in.plugin.len > 64) {
            return error.Invalid;
        }

        if (!try exists(ctx, in.plugin, in.page)) {
            return error.Invalid;
        }

        if (in.for_everyone) {
            return pin_for_everyone(ctx, in.plugin, in.page);
        }

        if (try pins.count(ctx.db, owner) >= per_user_max) {
            return error.Invalid;
        }

        try pins.add(ctx.db, owner, .{
            .plugin = in.plugin,
            .page = in.page,
        }, ctx.now_ms);

        return .{
            .plugin = in.plugin,
            .page = in.page,
        };
    }
};

pub const Unpin = struct {
    pub const name = "rail.unpin";
    pub const description = "Take a page off the caller's rail, or off everyone's";
    pub const details =
        \\The page itself stays where it is listed. Not pinned, nothing changes. A pin made
        \\for everyone is hidden from the caller's rail alone; `for_everyone` takes it off
        \\every rail (administrators only).
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        plugin: []const u8 = "",
        page: []const u8,
        for_everyone: bool = false,
    };
    pub const Out = Pinned;
    pub const example: In = .{
        .page = "settings/users",
    };
    pub const example_out: Out = .{
        .plugin = "",
        .page = "settings/users",
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .plugin = "The plugin whose page it is; empty for a core page",
        .page = "The page, as pinned",
        .for_everyone = "Off everyone's rail (administrators only)",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const owner = ctx.caller.user_id() orelse return error.Denied;
        const pin: pins.Pin = .{
            .plugin = in.plugin,
            .page = in.page,
        };

        if (in.page.len == 0 or in.page.len > pins.page_len_max) {
            return error.Invalid;
        }

        if (in.for_everyone) {
            if (!ctx.caller.holds("admin")) {
                return error.Denied;
            }

            _ = try shared_pins.remove(ctx.db, pin);
        } else if (!try pins.remove(ctx.db, owner, pin)) {
            if (listed(try shared_pins.list(ctx.db, ctx.arena), pin)) {
                try pins.hide(ctx.db, owner, pin, ctx.now_ms);
            }
        }

        return .{
            .plugin = in.plugin,
            .page = in.page,
        };
    }
};

pub const operations = [_]type{ List, Pin, Unpin };

fn pin_for_everyone(ctx: *Ctx, plugin: []const u8, page: []const u8) Error!Pinned {
    std.debug.assert(page.len > 0);
    std.debug.assert(shared_pins.count_max > 0);

    if (!ctx.caller.holds("admin")) {
        return error.Denied;
    }

    if (try shared_pins.count(ctx.db) >= shared_pins.count_max) {
        return error.Invalid;
    }

    try shared_pins.add(ctx.db, .{
        .plugin = plugin,
        .page = page,
    }, ctx.now_ms);

    return .{
        .plugin = plugin,
        .page = page,
        .shared = true,
    };
}

fn listed(list: []const pins.Pin, pin: pins.Pin) bool {
    std.debug.assert(pin.page.len > 0);

    for (list) |candidate| {
        const same_page = std.mem.eql(u8, candidate.page, pin.page);

        if (same_page and std.mem.eql(u8, candidate.plugin, pin.plugin)) {
            return true;
        }
    }

    return false;
}

/// Whether the page is one: a core page, a settings section, or one of the plugin's pages or
/// sections.
fn exists(ctx: *Ctx, plugin: []const u8, page: []const u8) Error!bool {
    std.debug.assert(page.len > 0);

    if (plugin.len == 0) {
        if (admin_pages.find(page) != null) {
            return true;
        }

        const handle = admin_pages.settings_handle(page) orelse return false;
        const row = try store.content_types.get_by_handle(ctx.db, ctx.arena, handle);

        return if (row) |found| found.def.kind == .settings else false;
    }

    return native_has(plugin, page) or sandboxed_has(ctx, plugin, page);
}

fn native_has(plugin: []const u8, page: []const u8) bool {
    std.debug.assert(plugin.len > 0);

    const section = admin_pages.section_handle(page);

    inline for (registry.pages) |owned| {
        if (std.mem.eql(u8, owned.plugin, plugin) and std.mem.eql(u8, owned.page.path, page)) {
            return true;
        }
    }

    if (section) |name| {
        return has_item(registry.menu, plugin, name);
    }

    return false;
}

/// Whether `plugin` brings the menu item `name` (`shop` for `products.shop`).
fn has_item(
    entries: []const model.sandboxed_plugin.MenuEntry,
    plugin: []const u8,
    name: []const u8,
) bool {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(name.len > 0);

    for (entries) |entry| {
        const dot = std.mem.indexOfScalar(u8, entry.name, '.') orelse continue;

        const same_plugin = std.mem.eql(u8, entry.name[0..dot], plugin);

        if (same_plugin and std.mem.eql(u8, entry.name[dot + 1 ..], name)) {
            return true;
        }
    }

    return false;
}

fn sandboxed_has(ctx: *Ctx, plugin: []const u8, page: []const u8) bool {
    std.debug.assert(plugin.len > 0);

    const sandboxed = ctx.sandboxed_plugins orelse return false;
    const section = admin_pages.section_handle(page);

    for (sandboxed.manifests()) |manifest| {
        if (!std.mem.eql(u8, manifest.name, plugin)) {
            continue;
        }

        for (manifest.pages) |one| {
            if (std.mem.eql(u8, one.path, page)) {
                return true;
            }
        }

        if (section) |name| {
            return has_item(manifest.menu, plugin, name);
        }
    }

    return false;
}

test "everyone's pins come first; a person hides one for themselves; administrators only" {
    const SDK = registry.SDK;
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);

    var admin = harness.ctx(.{
        .user = .{
            .id = "u_admin",
            .roles = &.{"admin"},
        },
    });
    const users = @import("user.zig");
    const root_account = try SDK.dispatch(&admin, users.Create, .{
        .email = "root@example.com",
        .display_name = "Root",
    });
    const ada_account = try SDK.dispatch(&admin, users.Create, .{
        .email = "ada@example.com",
        .display_name = "Ada",
    });
    var root = harness.ctx(.{
        .user = .{
            .id = root_account.user_id,
            .roles = &.{"admin"},
        },
    });
    var ada = harness.ctx(.{
        .user = .{
            .id = ada_account.user_id,
            .roles = &.{"editor"},
        },
    });
    const trash: Pin.In = .{
        .page = "trash",
        .for_everyone = true,
    };

    try std.testing.expectError(error.Denied, SDK.dispatch(&ada, Pin, trash));
    _ = try SDK.dispatch(&root, Pin, trash);
    _ = try SDK.dispatch(&ada, Pin, .{
        .page = "settings/users",
    });

    const rail = try SDK.dispatch(&ada, List, .{});
    try std.testing.expectEqual(@as(usize, 2), rail.pins.len);
    try std.testing.expect(rail.pins[0].shared);
    try std.testing.expectEqualStrings("trash", rail.pins[0].page);

    _ = try SDK.dispatch(&ada, Unpin, .{
        .page = "trash",
    });
    try std.testing.expectEqual(@as(usize, 1), (try SDK.dispatch(&ada, List, .{})).pins.len);
    try std.testing.expectEqual(@as(usize, 1), (try SDK.dispatch(&root, List, .{})).pins.len);

    _ = try SDK.dispatch(&ada, Pin, .{
        .page = "trash",
    });
    try std.testing.expectEqual(@as(usize, 2), (try SDK.dispatch(&ada, List, .{})).pins.len);

    try std.testing.expectError(error.Denied, SDK.dispatch(&ada, Unpin, .{
        .page = "trash",
        .for_everyone = true,
    }));
    _ = try SDK.dispatch(&root, Unpin, .{
        .page = "trash",
        .for_everyone = true,
    });
    try std.testing.expectEqual(@as(usize, 0), (try SDK.dispatch(&root, List, .{})).pins.len);
}
