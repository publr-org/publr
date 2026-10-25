//! The taxonomies a content type is filed under, and who put each there: the type's own list
//! (an administrator's ticks, its plugin's declarations), then every plugin's registration
//! whose `.to` picks the type, less those an administrator took off. A taxonomy that does not
//! exist yet waits; one the type's form holds in a `terms` field stays there, out of the
//! sidebar. Patterns pick record types only, and never an internal taxonomy.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const registry = @import("../../server/registry.zig");
const taxonomy_define = @import("../../sdk/plugin/taxonomy_define.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const Def = model.content_type.Def;

/// One taxonomy on a type, as its settings show it.
pub const Placed = struct {
    /// The taxonomy's handle.
    taxonomy: []const u8,
    /// Its name.
    name: []const u8,
    /// Who put it on the type: empty for an administrator, else the plugin.
    by: []const u8 = "",
    /// Declared by the type's own plugin: there while the plugin declares it.
    locked: bool = false,
    /// Put on by another plugin's `.register_taxonomies`: an administrator may take it off.
    registered: bool = false,
    /// A registration an administrator took off: hidden, its assignments kept.
    removed: bool = false,
    /// Never reaches the site.
    internal: bool = false,
};

/// A placed taxonomy and its definition.
pub const Found = struct {
    placed: Placed,
    row: store.taxonomies.Row,
};

pub const Options = struct {
    /// Also the registrations an administrator took off, marked `removed`.
    removed: bool = false,
};

/// Every taxonomy on the type, own first, then registrations in plugin order.
pub fn of(ctx: *Ctx, def: Def, options: Options) Error![]const Found {
    std.debug.assert(def.handle.len > 0);
    std.debug.assert(def.taxonomies.len <= model.content_type.taxonomies_max);

    var found: std.ArrayList(Found) = .empty;

    for (def.taxonomies) |classified| {
        if (classified.removed or in_form(def, classified.taxonomy)) {
            continue;
        }

        const handle = classified.taxonomy;
        const row = try store.taxonomies.get_by_handle(ctx.db, ctx.arena, handle) orelse continue;

        try found.append(ctx.arena, .{
            .placed = .{
                .taxonomy = row.def.handle,
                .name = row.def.name,
                .by = if (classified.locked) def.owner else "",
                .locked = classified.locked,
                .internal = row.def.internal,
            },
            .row = row,
        });
    }

    if (def.kind != .record and def.kind != .media) {
        return found.items;
    }

    for (try registry.taxonomy_registrations(ctx)) |entry| {
        const pick = picks(entry.to, def);

        if (pick == .none or listed(found.items, entry.taxonomy)) {
            continue;
        }

        if (in_form(def, entry.taxonomy)) {
            continue;
        }

        const removed = removed_from(def, entry.taxonomy);

        if (removed and !options.removed) {
            continue;
        }

        const row = try store.taxonomies.get_by_handle(ctx.db, ctx.arena, entry.taxonomy) orelse
            continue;

        if (row.def.internal and pick != .exact) {
            continue;
        }

        try found.append(ctx.arena, .{
            .placed = .{
                .taxonomy = row.def.handle,
                .name = row.def.name,
                .by = entry.plugin,
                .registered = true,
                .removed = removed,
                .internal = row.def.internal,
            },
            .row = row,
        });
    }

    return found.items;
}

/// The types a taxonomy is on and who put it on each: what its screen shows as "Used by".
pub const UsedBy = struct {
    /// The type's handle.
    type: []const u8,
    /// Its name.
    name: []const u8,
    /// Who put the taxonomy there: empty for an administrator, else the plugin.
    by: []const u8 = "",
    /// Taken off by an administrator: hidden, its assignments kept.
    removed: bool = false,
};

pub fn used_by(ctx: *Ctx, handle: []const u8) Error![]const UsedBy {
    std.debug.assert(handle.len > 0);
    std.debug.assert(store.content_types.list_max > 0);

    const types = try store.content_types.list(ctx.db, ctx.arena);
    var users: std.ArrayList(UsedBy) = .empty;

    for (types) |row| {
        const placed = try of(ctx, row.def, .{
            .removed = true,
        });

        for (placed) |each| {
            if (std.mem.eql(u8, each.placed.taxonomy, handle)) {
                try users.append(ctx.arena, .{
                    .type = row.def.handle,
                    .name = row.def.name,
                    .by = each.placed.by,
                    .removed = each.placed.removed,
                });
            }
        }

        // A `terms` field of the form naming it is a use too, the administrator's or the
        // type's plugin's.
        if (in_form(row.def, handle)) {
            try users.append(ctx.arena, .{
                .type = row.def.handle,
                .name = row.def.name,
                .by = row.def.owner,
            });
        }
    }

    return users.items;
}

/// What a plugin's registrations name that is not there although its plugin is: one line
/// each, for the plugin's page. A plugin that must have the type says so in `.depends_on`.
pub fn missing_types(ctx: *Ctx, plugin: []const u8) Error![]const []const u8 {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    var lines: std.ArrayList([]const u8) = .empty;

    for (try registry.taxonomy_registrations(ctx)) |entry| {
        if (!std.mem.eql(u8, entry.plugin, plugin)) {
            continue;
        }

        for (entry.to) |pattern| {
            const dot = std.mem.indexOfScalar(u8, pattern, '.') orelse continue;
            const owner = pattern[0..dot];

            if (!taxonomy_define.is_exact(pattern) or !registry.plugin_present(ctx, owner)) {
                continue;
            }

            if (try store.content_types.get_by_handle(ctx.db, ctx.arena, pattern) != null) {
                continue;
            }

            try lines.append(ctx.arena, try std.fmt.allocPrint(
                ctx.arena,
                "{s} is here but has no type {s}: {s} waits for it",
                .{ owner, pattern, entry.taxonomy },
            ));
        }
    }

    return lines.items;
}

const Pick = enum { none, exact, pattern };

/// Whether a registration's `.to` picks the type: by its name (a record or media type), or
/// by a pattern (record types only).
fn picks(to: []const []const u8, def: Def) Pick {
    std.debug.assert(to.len <= taxonomy_define.to_max);
    std.debug.assert(def.handle.len > 0);

    var found: Pick = .none;

    for (to) |pattern| {
        if (!taxonomy_define.matches(pattern, def.handle)) {
            continue;
        }

        if (taxonomy_define.is_exact(pattern)) {
            return .exact;
        }

        if (def.kind == .record) {
            found = .pattern;
        }
    }

    return found;
}

fn listed(found: []const Found, handle: []const u8) bool {
    std.debug.assert(handle.len > 0);

    for (found) |each| {
        if (std.mem.eql(u8, each.placed.taxonomy, handle)) {
            return true;
        }
    }

    return false;
}

fn removed_from(def: Def, handle: []const u8) bool {
    std.debug.assert(handle.len > 0);

    for (def.taxonomies) |classified| {
        if (classified.removed and std.mem.eql(u8, classified.taxonomy, handle)) {
            return true;
        }
    }

    return false;
}

/// Whether the type's form holds the taxonomy in a `terms` field of its own.
fn in_form(def: Def, handle: []const u8) bool {
    std.debug.assert(handle.len > 0);
    std.debug.assert(def.fields.len <= model.field.fields_max);

    var each = model.taxonomy.terms_fields(def.fields);

    while (each.next()) |terms| {
        if (!model.taxonomy.is_implicit(terms.*) and
            std.mem.eql(u8, terms.options.taxonomy, handle))
        {
            return true;
        }
    }

    return false;
}
