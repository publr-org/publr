const std = @import("std");
const sdk = @import("../sdk.zig");
const registry = @import("../server/registry.zig");
const model = @import("../model.zig");
const store = @import("../store.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const pins = store.rail_pins;
const admin_pages = model.admin_pages;

pub const namespace: sdk.operation.Namespace = .{
    .name = "rail",
    .summary = "The pages a person pins to their rail",
    .details =
    \\The rail holds Overview, Content and Media, then what the person pinned, in the order
    \\pinned. Nothing else adds to it: a plugin registers pages and sections, and people pin
    \\the ones they use. A pin names a page: a core one by its address below `/admin/`
    \\(`settings/users`, `trash`, `settings/<handle>` for a settings section), or a plugin's
    \\by the plugin and its page (a page's path, a settings page's address, or
    \\`section/<handle>` for a section, named by its first type). Each person pins for
    \\themselves; a page they may not see is not drawn. Signed-in callers only.
    ,
};

pub const per_user_max = pins.per_user_max;

pub const Pinned = struct {
    plugin: []const u8,
    page: []const u8,
};

pub const List = struct {
    pub const name = "rail.list";
    pub const description = "List the pages the caller pinned to their rail, top to bottom";
    pub const details =
        \\The caller's own pins. A pin whose page is gone (its plugin removed) stays listed
        \\and is not drawn; unpin it to drop it.
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
        const rows = try pins.list(ctx.db, ctx.arena, owner);
        const out = ctx.arena.alloc(Pinned, rows.len) catch return error.OutOfMemory;

        for (rows, out) |row, *pinned| {
            pinned.* = .{
                .plugin = row.plugin,
                .page = row.page,
            };
        }

        return .{
            .pins = out,
        };
    }
};

pub const Pin = struct {
    pub const name = "rail.pin";
    pub const description = "Pin a page to the caller's rail, below the others";
    pub const details =
        \\`page` alone for a core page; `plugin` and `page` for a plugin's. Invalid unless the
        \\page exists. Pinned already, it stays where it is. Up to 16 pins.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        plugin: []const u8 = "",
        page: []const u8,
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
        .page = "The page: `settings/users`, a plugin page's path, `section/<handle>`",
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
    pub const description = "Take a page off the caller's rail";
    pub const details =
        \\The page itself stays where it is listed. Not pinned, nothing changes.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        plugin: []const u8 = "",
        page: []const u8,
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
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const owner = ctx.caller.user_id() orelse return error.Denied;

        if (in.page.len == 0 or in.page.len > pins.page_len_max) {
            return error.Invalid;
        }

        _ = try pins.remove(ctx.db, owner, .{
            .plugin = in.plugin,
            .page = in.page,
        });

        return .{
            .plugin = in.plugin,
            .page = in.page,
        };
    }
};

pub const operations = [_]type{ List, Pin, Unpin };

/// Whether the page is one: a core page, a settings section, or one of the plugin's pages,
/// settings pages or sections.
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

    inline for (registry.settings_pages) |owned| {
        if (std.mem.eql(u8, owned.plugin, plugin) and std.mem.eql(u8, owned.page.path, page)) {
            return true;
        }
    }

    inline for (registry.sections) |owned| {
        const first = owned.section.types[0].handle;
        const named = if (section) |handle| std.mem.eql(u8, first, handle) else false;

        if (std.mem.eql(u8, owned.plugin, plugin) and named) {
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

        for (manifest.sections) |one| {
            const handle = section orelse break;

            if (one.types.len > 0 and std.mem.eql(u8, one.types[0].handle, handle)) {
                return true;
            }
        }
    }

    return false;
}
