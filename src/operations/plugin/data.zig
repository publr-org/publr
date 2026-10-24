//! What a plugin's data is, read from the database: the content types it owns with their
//! records, the collections of internal records it keeps, the custom field groups and the
//! roles it declared. Each a piece with a key (`type:<handle>`, `internal:<collection>`,
//! `fields:<group>`, `role:<name>`), so an administrator chooses which go when it is
//! removed, and the removal takes those into the plugin's trash entry.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const state = @import("state.zig");
const record = @import("../record.zig");
const role_rows = @import("../role/rows.zig");
const changes = @import("../project/changes.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const Root = store.trash_copy.Root;
const definition = record.domain.definition;

pub const pieces_max: u32 = 96;

pub const Kind = enum { type, internal, fields, role };

pub const Piece = struct {
    key: []const u8,
    kind: Kind,
    /// As the admin names it: the type's or group's name, the collection's.
    label: []const u8,
    /// Records or internal records it holds, the accounts holding a role; 0 for a field
    /// group.
    count: u32,
    /// Chosen to go with the plugin when it is removed.
    chosen: bool,
};

pub fn pieces_of(ctx: *Ctx, decoded: state.Decoded) Error![]Piece {
    std.debug.assert(decoded.manifest.name.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    const name = decoded.manifest.name;
    const chosen = try chosen_of(ctx, name);
    var pieces: std.ArrayList(Piece) = .empty;

    for (decoded.manifest.content_types) |def| {
        const row = try store.content_types.get_by_handle(ctx.db, ctx.arena, def.handle) orelse
            continue;

        if (!std.mem.eql(u8, row.def.owner, name)) {
            continue;
        }

        const key = try key_of(ctx, "type", def.handle);

        try append(ctx, &pieces, .{
            .key = key,
            .kind = .type,
            .label = row.def.name,
            .count = try store.records.count_by_type(ctx.db, row.id),
            .chosen = has(chosen, key),
        });
    }

    for (try store.internal_records.collections_of(ctx.db, ctx.arena, name)) |collection| {
        const key = try key_of(ctx, "internal", collection.kind);

        try append(ctx, &pieces, .{
            .key = key,
            .kind = .internal,
            .label = collection.kind,
            .count = @intCast(@min(collection.count, std.math.maxInt(u32))),
            .chosen = has(chosen, key),
        });
    }

    for (decoded.manifest.custom_fields) |def| {
        const found = try store.field_groups.get(ctx.db, ctx.arena, .custom_fields, def.handle);

        if (found == null) {
            continue;
        }

        const key = try key_of(ctx, "fields", def.handle);

        try append(ctx, &pieces, .{
            .key = key,
            .kind = .fields,
            .label = if (def.name.len > 0) def.name else def.handle,
            .count = 0,
            .chosen = has(chosen, key),
        });
    }

    for (decoded.manifest.roles) |declared| {
        const row = try store.roles.get(ctx.db, ctx.arena, declared.name) orelse continue;

        if (!std.mem.eql(u8, row.owner, name)) {
            continue;
        }

        const key = try key_of(ctx, "role", declared.name);

        try append(ctx, &pieces, .{
            .key = key,
            .kind = .role,
            .label = row.label,
            .count = try store.user_roles.holders(ctx.db, row.name),
            .chosen = has(chosen, key),
        });
    }

    return pieces.items;
}

/// Keeps the keys asked for, each one of the plugin's pieces; refused otherwise.
pub fn choose(ctx: *Ctx, decoded: state.Decoded, keys: []const []const u8) Error!void {
    std.debug.assert(decoded.manifest.name.len > 0);

    if (keys.len > pieces_max) {
        return error.Invalid;
    }

    const pieces = try pieces_of(ctx, decoded);

    for (keys) |key| {
        if (find(pieces, key) == null) {
            return error.Invalid;
        }
    }

    const text = std.json.Stringify.valueAlloc(ctx.arena, keys, .{}) catch return error.OutOfMemory;

    try store.sandboxed_plugins.set_removal(ctx.db, decoded.manifest.name, text);
}

/// The chosen pieces, as they are now.
pub fn going(ctx: *Ctx, decoded: state.Decoded) Error![]const Piece {
    std.debug.assert(decoded.manifest.name.len > 0);

    const pieces = try pieces_of(ctx, decoded);
    var chosen: std.ArrayList(Piece) = .empty;

    for (pieces) |piece| {
        if (piece.chosen) {
            chosen.append(ctx.arena, piece) catch return error.OutOfMemory;
        }
    }

    return chosen.items;
}

/// What a copy of the pieces holds, for the plugin's trash entry.
pub fn roots_of(ctx: *Ctx, plugin: []const u8, pieces: []const Piece) Error![]const Root {
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
            .internal => {
                const ids = try internal_ids(ctx, plugin, handle);

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

/// Deletes the pieces, their copy kept in the plugin's trash entry already. Answers the
/// handles of the content types it deleted.
pub fn drop(ctx: *Ctx, plugin: []const u8, pieces: []const Piece) Error![]const []const u8 {
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

        const written = switch (piece.kind) {
            .type => text.print(ctx.arena, "{s}{s} ({d} records)", .{
                separator,
                piece.label,
                piece.count,
            }),
            .internal => text.print(ctx.arena, "{s}{s} ({d} internal records)", .{
                separator,
                piece.label,
                piece.count,
            }),
            .fields => text.print(ctx.arena, "{s}{s} (field group)", .{ separator, piece.label }),
            .role => text.print(ctx.arena, "{s}{s} (role, {d} holders)", .{
                separator,
                piece.label,
                piece.count,
            }),
        };

        written catch return error.OutOfMemory;
    }

    return text.items;
}

fn internal_ids(ctx: *Ctx, plugin: []const u8, kind: []const u8) Error![]const u8 {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(kind.len > 0);

    return store.internal_records.ids_of_collection(ctx.db, ctx.arena, plugin, kind);
}

fn chosen_of(ctx: *Ctx, plugin: []const u8) Error![]const []const u8 {
    std.debug.assert(plugin.len > 0);

    const text = try store.sandboxed_plugins.removal_of(ctx.db, ctx.arena, plugin);

    return std.json.parseFromSliceLeaky([]const []const u8, ctx.arena, text, .{}) catch &.{};
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
