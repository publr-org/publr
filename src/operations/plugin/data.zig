//! What a plugin's data is, read from the database by owner: the content types it owns with
//! their records, the taxonomies with their terms, the collections of internal records it
//! keeps, the custom field groups and the roles it declared. Each a piece with a key
//! (`type:<handle>`, `taxonomy:<handle>`, `internal:<collection>`, `fields:<group>`,
//! `role:<name>`). Found by owner, so a plugin's data is still listed after it is uninstalled.
//! Uninstalling decides each piece: kept where it is, moved to the trash (its own entry,
//! keyed `<plugin>/<piece>`), or erased for good. What is kept or in the trash stays listed
//! under the plugin's name until it is purged or brought back.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const record = @import("../record.zig");
const role_rows = @import("../role/rows.zig");
const changes = @import("../project/changes.zig");
const trash = @import("../trash.zig");
const registry = @import("../../server/registry.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const Root = store.trash_copy.Root;
const definition = record.domain.definition;
const taxonomy_definition = @import("../term.zig").domain.definition;

pub const pieces_max: u32 = 96;

/// The trash entries of plugins' data are this kind, keyed `<plugin>/<piece>`.
pub const trash_kind = "plugin_data";

pub const Kind = enum { type, taxonomy, internal, fields, role };

pub const Piece = struct {
    key: []const u8,
    kind: Kind,
    /// As the admin names it: the type's or group's name, the collection's.
    label: []const u8,
    /// Records, terms or internal records it holds, the accounts holding a role; 0 for a
    /// field group.
    count: u32,
    /// Its trash entry when it is in the trash; empty when it is kept where it is.
    trash: []const u8 = "",
};

/// What happens to a piece when its plugin is uninstalled.
pub const Fate = enum { keep, trash, erase };

/// The plugin's pieces where they are, then those in the trash.
pub fn pieces_of(ctx: *Ctx, name: []const u8) Error![]Piece {
    std.debug.assert(name.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    var pieces: std.ArrayList(Piece) = .empty;

    for (try store.content_types.list_briefs(ctx.db, ctx.arena)) |brief| {
        if (!std.mem.eql(u8, brief.owner, name)) {
            continue;
        }

        try append(ctx, &pieces, .{
            .key = try key_of(ctx, "type", brief.handle),
            .kind = .type,
            .label = brief.name,
            .count = try store.records.count_by_type(ctx.db, brief.id),
        });
    }

    // Its taxonomies on other plugins' types have no data of their own: the terms follow
    // their taxonomy's piece.
    for (try store.taxonomies.list_briefs(ctx.db, ctx.arena)) |brief| {
        if (!std.mem.eql(u8, brief.owner, name)) {
            continue;
        }

        try append(ctx, &pieces, .{
            .key = try key_of(ctx, "taxonomy", brief.handle),
            .kind = .taxonomy,
            .label = brief.name,
            .count = try store.terms.count_by_type(ctx.db, brief.id),
        });
    }

    for (try store.internal_records.collections_of(ctx.db, ctx.arena, name)) |collection| {
        try append(ctx, &pieces, .{
            .key = try key_of(ctx, "internal", collection.kind),
            .kind = .internal,
            .label = collection.kind,
            .count = @intCast(@min(collection.count, std.math.maxInt(u32))),
        });
    }

    for (try store.field_groups.list(ctx.db, ctx.arena, .custom_fields)) |item| {
        const group = group_of(ctx, item.definition) orelse continue;

        if (!std.mem.eql(u8, group.owner, name)) {
            continue;
        }

        try append(ctx, &pieces, .{
            .key = try key_of(ctx, "fields", item.owner),
            .kind = .fields,
            .label = if (group.name.len > 0) group.name else item.owner,
            .count = 0,
        });
    }

    for (try store.roles.list(ctx.db, ctx.arena)) |row| {
        if (!std.mem.eql(u8, row.owner, name)) {
            continue;
        }

        try append(ctx, &pieces, .{
            .key = try key_of(ctx, "role", row.name),
            .kind = .role,
            .label = row.label,
            .count = try store.user_roles.holders(ctx.db, row.name),
        });
    }

    for (try in_trash(ctx, name)) |entry| {
        try append(ctx, &pieces, try trashed_piece(ctx, entry));
    }

    return pieces.items;
}

/// The plugin's pieces in the trash, each its own entry.
fn in_trash(ctx: *Ctx, name: []const u8) Error![]const store.trash.Entry {
    std.debug.assert(name.len > 0);

    return store.trash.under(ctx.db, ctx.arena, trash_kind, name, pieces_max);
}

/// A piece as its trash entry names it: the key after the plugin's, the entry's words.
fn trashed_piece(ctx: *Ctx, entry: store.trash.Entry) Error!Piece {
    std.debug.assert(entry.key.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    const slash = std.mem.indexOfScalar(u8, entry.key, '/') orelse return error.Invalid;
    const key = entry.key[slash + 1 ..];
    const colon = std.mem.indexOfScalar(u8, key, ':') orelse return error.Invalid;
    const kind = std.meta.stringToEnum(Kind, key[0..colon]) orelse return error.Invalid;

    const suffix = std.fmt.allocPrint(ctx.arena, ", from {s}", .{entry.key[0..slash]}) catch
        return error.OutOfMemory;
    const label = if (std.mem.endsWith(u8, entry.label, suffix))
        entry.label[0 .. entry.label.len - suffix.len]
    else
        entry.label;

    return .{
        .key = key,
        .kind = kind,
        .label = label,
        .count = 0,
        .trash = entry.id,
    };
}

/// Uninstalling: each piece named in `trash` goes to the trash as an entry of its own; the
/// rest stay. Erasing is `erase`'s, after the plugin is gone.
pub fn put_in_trash(ctx: *Ctx, plugin: []const u8, keys: []const []const u8) Error!void {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(ctx.db.transaction_depth >= 1);

    if (keys.len > pieces_max) {
        return error.Invalid;
    }

    const pieces = try pieces_of(ctx, plugin);

    for (keys) |key| {
        const piece = find(pieces, key) orelse return error.Invalid;

        if (piece.trash.len > 0) {
            continue;
        }

        const one = [_]Piece{piece};
        const label = std.fmt.allocPrint(ctx.arena, "{s}, from {s}", .{
            try summary_of(ctx, &one),
            plugin,
        }) catch return error.OutOfMemory;

        _ = try trash.keep(ctx, .{
            .kind = trash_kind,
            .key = std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ plugin, piece.key }) catch
                return error.OutOfMemory,
            .label = label,
            .roots = try roots_of(ctx, plugin, &one),
        });
        _ = try drop(ctx, plugin, &one);
    }
}

/// Brings the pieces named back from the trash. A content type or taxonomy the plugin made
/// again since, still empty, gives way to the one coming back.
pub fn restore(ctx: *Ctx, plugin: []const u8, keys: []const []const u8) Error!void {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(ctx.db.transaction_depth >= 1);

    if (keys.len == 0 or keys.len > pieces_max) {
        return error.Invalid;
    }

    const pieces = try pieces_of(ctx, plugin);

    for (keys) |key| {
        const piece = find_trashed(pieces, key) orelse return error.Invalid;

        try make_room(ctx, plugin, piece);
        _ = try registry.SDK.dispatch(ctx, trash.Restore, .{
            .id = piece.trash,
        });
    }
}

/// An empty type or taxonomy of the plugin's under the handle a trashed piece brings back.
fn make_room(ctx: *Ctx, plugin: []const u8, piece: Piece) Error!void {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(piece.trash.len > 0);

    const handle = handle_of(piece.key);

    switch (piece.kind) {
        .type => {
            const row = try store.content_types.get_by_handle(ctx.db, ctx.arena, handle) orelse
                return;
            const empty = try store.records.count_by_type(ctx.db, row.id) == 0;

            if (empty and std.mem.eql(u8, row.def.owner, plugin)) {
                try definition.drop_kept(ctx, row.id);
            }
        },
        .taxonomy => {
            const row = try store.taxonomies.get_by_handle(ctx.db, ctx.arena, handle) orelse
                return;
            const empty = try store.terms.count_by_type(ctx.db, row.id) == 0;

            if (empty and std.mem.eql(u8, row.def.owner, plugin)) {
                try taxonomy_definition.drop_kept(ctx, row.id);
            }
        },
        .internal, .fields, .role => {},
    }
}

fn find_trashed(pieces: []const Piece, key: []const u8) ?Piece {
    std.debug.assert(pieces.len <= pieces_max);

    for (pieces) |piece| {
        if (piece.trash.len > 0 and std.mem.eql(u8, piece.key, key)) {
            return piece;
        }
    }

    return null;
}

/// Erases the pieces named for good: one kept is deleted with no copy, one in the trash has
/// its entry removed. Answers what went, in words, for the log.
pub fn erase(ctx: *Ctx, plugin: []const u8, keys: []const []const u8) Error![]const u8 {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(ctx.db.transaction_depth >= 1);

    if (keys.len == 0 or keys.len > pieces_max) {
        return error.Invalid;
    }

    const pieces = try pieces_of(ctx, plugin);
    var going: std.ArrayList(Piece) = .empty;

    for (keys) |key| {
        const piece = find(pieces, key) orelse return error.Invalid;

        going.append(ctx.arena, piece) catch return error.OutOfMemory;
    }

    for (going.items) |piece| {
        if (piece.trash.len > 0) {
            _ = try trash.drop(ctx, piece.trash);
        } else {
            const one = [_]Piece{piece};

            _ = try drop(ctx, plugin, &one);
        }
    }

    return summary_of(ctx, going.items);
}

/// The names of plugins that are not installed and still have data: kept where it is, or
/// in the trash.
pub fn left_behind(ctx: *Ctx, installed: []const []const u8) Error![]const []const u8 {
    std.debug.assert(installed.len <= 1024);

    var names: std.ArrayList([]const u8) = .empty;

    for (try store.content_types.list_briefs(ctx.db, ctx.arena)) |brief| {
        try add_name(ctx, &names, installed, brief.owner);
    }

    for (try store.taxonomies.list_briefs(ctx.db, ctx.arena)) |brief| {
        try add_name(ctx, &names, installed, brief.owner);
    }

    for (try store.internal_records.plugins(ctx.db, ctx.arena)) |plugin| {
        try add_name(ctx, &names, installed, plugin);
    }

    for (try store.field_groups.list(ctx.db, ctx.arena, .custom_fields)) |item| {
        const group = group_of(ctx, item.definition) orelse continue;

        try add_name(ctx, &names, installed, group.owner);
    }

    for (try store.roles.list(ctx.db, ctx.arena)) |row| {
        try add_name(ctx, &names, installed, row.owner);
    }

    const keys = try store.trash.keys_of(ctx.db, ctx.arena, trash_kind, store.trash.entries_max);

    for (keys) |key| {
        const slash = std.mem.indexOfScalar(u8, key, '/') orelse continue;

        try add_name(ctx, &names, installed, key[0..slash]);
    }

    std.mem.sort([]const u8, names.items, {}, less);

    return names.items;
}

fn less(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

/// A plugin's name once, unless it is installed, core's (`core`, `publr`) or the site's.
fn add_name(
    ctx: *Ctx,
    names: *std.ArrayList([]const u8),
    installed: []const []const u8,
    owner: []const u8,
) Error!void {
    std.debug.assert(names.items.len <= pieces_max);

    const core = std.mem.eql(u8, owner, "core") or std.mem.eql(u8, owner, "publr");

    if (owner.len == 0 or core or has(installed, owner)) {
        return;
    }

    if (has(names.items, owner) or names.items.len == pieces_max) {
        return;
    }

    names.append(ctx.arena, owner) catch return error.OutOfMemory;
}

/// What a copy of the pieces holds, for a trash entry.
fn roots_of(ctx: *Ctx, plugin: []const u8, pieces: []const Piece) Error![]const Root {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(pieces.len <= pieces_max);

    var roots: std.ArrayList(Root) = .empty;

    for (pieces) |piece| {
        const handle = handle_of(piece.key);

        switch (piece.kind) {
            .type => {
                const row = try store.content_types.get_by_handle(ctx.db, ctx.arena, handle) orelse
                    continue;

                roots.appendSlice(ctx.arena, try definition.roots_of(ctx, row.id)) catch {
                    return error.OutOfMemory;
                };
            },
            .taxonomy => {
                const row = try store.taxonomies.get_by_handle(ctx.db, ctx.arena, handle) orelse
                    continue;
                const kept = try taxonomy_definition.roots_of(ctx, row.id);

                roots.appendSlice(ctx.arena, kept) catch return error.OutOfMemory;
            },
            .internal => {
                const ids = try store.internal_records.ids_of_collection(
                    ctx.db,
                    ctx.arena,
                    plugin,
                    handle,
                );

                const of_collection: Root = .{
                    .table = "internal_records",
                    .column = "id",
                    .keys = ids,
                };

                roots.append(ctx.arena, of_collection) catch return error.OutOfMemory;
            },
            .fields => roots.append(ctx.arena, .{
                .table = "field_groups",
                .column = "owner",
                .keys = try quoted(ctx, handle),
            }) catch return error.OutOfMemory,
            .role => roots.appendSlice(ctx.arena, try role_rows.roots_of(ctx, handle)) catch {
                return error.OutOfMemory;
            },
        }
    }

    return roots.items;
}

/// Deletes the pieces where they are. Answers the handles of the content types it deleted.
fn drop(ctx: *Ctx, plugin: []const u8, pieces: []const Piece) Error![]const []const u8 {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(ctx.db.transaction_depth >= 1);

    var types: std.ArrayList([]const u8) = .empty;

    for (pieces) |piece| {
        const handle = handle_of(piece.key);

        switch (piece.kind) {
            .type => {
                const row = try store.content_types.get_by_handle(ctx.db, ctx.arena, handle) orelse
                    continue;

                try definition.drop_kept(ctx, row.id);
                types.append(ctx.arena, handle) catch return error.OutOfMemory;
            },
            .taxonomy => {
                const row = try store.taxonomies.get_by_handle(ctx.db, ctx.arena, handle) orelse
                    continue;

                try taxonomy_definition.drop_kept(ctx, row.id);
            },
            .internal => {
                try store.internal_records.delete_collection(ctx.db, plugin, handle);
                changes.internal_changed(ctx, plugin, handle, null) catch |err| {
                    if (err == error.OutOfMemory) {
                        return error.OutOfMemory;
                    }

                    ctx.dependency_failure = true;
                };
            },
            .fields => try store.field_groups.delete(ctx.db, .custom_fields, handle),
            .role => {
                if (try store.user_roles.sole_holders(ctx.db, handle) > 0) {
                    return error.Conflict;
                }

                try role_rows.drop(ctx, handle);
                try store.role_declarations.forget_role(ctx.db, handle);
            },
        }
    }

    return types.items;
}

/// "Course (12 records), enrolments (340 internal records), SEO (field group)".
pub fn summary_of(ctx: *Ctx, pieces: []const Piece) Error![]const u8 {
    std.debug.assert(pieces.len <= pieces_max);

    var text: std.ArrayList(u8) = .empty;

    for (pieces, 0..) |piece, index| {
        const separator: []const u8 = if (index > 0) ", " else "";

        const one = piece.count == 1;
        const written = switch (piece.kind) {
            .type => text.print(ctx.arena, "{s}{s} ({d} {s})", .{
                separator,
                piece.label,
                piece.count,
                if (one) "record" else "records",
            }),
            .taxonomy => text.print(ctx.arena, "{s}{s} ({d} {s})", .{
                separator,
                piece.label,
                piece.count,
                if (one) "term" else "terms",
            }),
            .internal => text.print(ctx.arena, "{s}{s} ({d} internal {s})", .{
                separator,
                piece.label,
                piece.count,
                if (one) "record" else "records",
            }),
            .fields => text.print(ctx.arena, "{s}{s} (field group)", .{ separator, piece.label }),
            .role => text.print(ctx.arena, "{s}{s} (role, {d} {s})", .{
                separator,
                piece.label,
                piece.count,
                if (one) "holder" else "holders",
            }),
        };

        written catch return error.OutOfMemory;
    }

    return text.items;
}

/// A custom field group's owner and name, read from its stored definition.
const Group = struct {
    owner: []const u8 = "",
    name: []const u8 = "",
};

fn group_of(ctx: *Ctx, text: []const u8) ?Group {
    std.debug.assert(text.len > 0);

    return std.json.parseFromSliceLeaky(Group, ctx.arena, text, .{
        .ignore_unknown_fields = true,
    }) catch null;
}

fn append(ctx: *Ctx, pieces: *std.ArrayList(Piece), piece: Piece) Error!void {
    std.debug.assert(piece.key.len > 0);

    if (pieces.items.len == pieces_max) {
        return;
    }

    pieces.append(ctx.arena, piece) catch return error.OutOfMemory;
}

fn key_of(ctx: *Ctx, kind: []const u8, handle: []const u8) Error![]const u8 {
    std.debug.assert(kind.len > 0);

    return std.fmt.allocPrint(ctx.arena, "{s}:{s}", .{ kind, handle }) catch error.OutOfMemory;
}

fn handle_of(key: []const u8) []const u8 {
    std.debug.assert(key.len > 0);

    const colon = std.mem.indexOfScalar(u8, key, ':') orelse return key;

    return key[colon + 1 ..];
}

fn quoted(ctx: *Ctx, value: []const u8) Error![]const u8 {
    std.debug.assert(value.len > 0);

    const one = [_][]const u8{value};

    return std.json.Stringify.valueAlloc(ctx.arena, &one, .{}) catch error.OutOfMemory;
}

fn has(keys: []const []const u8, key: []const u8) bool {
    std.debug.assert(key.len > 0);

    for (keys) |one| {
        if (std.mem.eql(u8, one, key)) {
            return true;
        }
    }

    return false;
}

fn find(pieces: []const Piece, key: []const u8) ?Piece {
    std.debug.assert(pieces.len <= pieces_max);

    for (pieces) |piece| {
        if (std.mem.eql(u8, piece.key, key)) {
            return piece;
        }
    }

    return null;
}
