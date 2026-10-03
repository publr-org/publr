//! Virtual fields as the editor sees and saves them. Reading for edit puts in place of the
//! ids a field keeps the ids of every record pointing here now (pending edits counted), in
//! the kept order; saving one writes the difference into those records' references: a
//! record left out has its reference cleared (or this id taken out of a multiple one), a
//! record added has it pointed here. Each write is a `record.save` as the caller in the
//! record's own status: a live record's reference changes live, its status untouched.

const std = @import("std");
const sdk = @import("../../../sdk.zig");
const registry = @import("../../../server/registry.zig");
const model = @import("../../../model.zig");
const records = @import("../../record.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const Value = std.json.Value;

/// The records one virtual field may list, at most.
pub const members_max: u32 = 1_000;

/// The edit document with each virtual field holding its members' ids.
pub fn with_members(
    ctx: *Ctx,
    granted: *const Grant,
    record: records.Record,
    text: []const u8,
) Error![]const u8 {
    std.debug.assert(record.id.len > 0);
    std.debug.assert(granted.allows());

    const row = try records.domain.definition.find(ctx, record.type) orelse return text;

    if (!has_virtual(row.def.fields)) {
        return text;
    }

    const arena = ctx.arena;
    var document = std.json.parseFromSliceLeaky(Value, arena, text, .{}) catch return text;

    if (document != .object) {
        return text;
    }

    for (row.def.fields) |def| {
        if (!is_referenced_by(def)) {
            continue;
        }

        const ids = try members(ctx, granted, record.id, def, document.object.get(def.name));

        document.object.put(arena, def.name, try ids_value(arena, ids)) catch {
            return error.OutOfMemory;
        };
    }

    return std.json.Stringify.valueAlloc(arena, document, .{}) catch error.OutOfMemory;
}

/// Before a save: each virtual field the document gives, its difference written into the
/// records it lists or no longer lists.
pub fn apply(ctx: *Ctx, granted: *const Grant, id: []const u8, text: []const u8) Error!void {
    std.debug.assert(id.len > 0);
    std.debug.assert(granted.allows());

    const arena = ctx.arena;
    const given = std.json.parseFromSliceLeaky(Value, arena, text, .{}) catch return;

    if (given != .object) {
        return;
    }

    const got = try records.domain.crud.get(ctx, granted, id, .edit, null);
    const row = try records.domain.definition.find(ctx, got.record.type) orelse return;

    for (row.def.fields) |def| {
        if (!is_referenced_by(def)) {
            continue;
        }

        const wanted = given.object.get(def.name) orelse continue;
        const current = try members(ctx, granted, id, def, null);

        try write_difference(ctx, granted, id, def, current, try ids_of(arena, wanted));
    }
}

fn write_difference(
    ctx: *Ctx,
    granted: *const Grant,
    parent: []const u8,
    def: model.field.Def,
    current: []const []const u8,
    wanted: []const []const u8,
) Error!void {
    std.debug.assert(parent.len > 0);
    std.debug.assert(current.len <= members_max);

    for (current) |child| {
        if (!contains(wanted, child)) {
            try repoint(ctx, granted, child, def, parent, .leave);
        }
    }

    for (wanted) |child| {
        if (!contains(current, child)) {
            try repoint(ctx, granted, child, def, parent, .join);
        }
    }
}

const Move = enum { join, leave };

/// One child's reference changed to join or leave the parent, saved as the caller.
fn repoint(
    ctx: *Ctx,
    granted: *const Grant,
    child: []const u8,
    def: model.field.Def,
    parent: []const u8,
    move: Move,
) Error!void {
    std.debug.assert(child.len > 0);
    std.debug.assert(!std.mem.eql(u8, child, parent));

    const arena = ctx.arena;
    const got = try records.domain.crud.get(ctx, granted, child, .edit, null);

    if (!std.mem.eql(u8, got.record.type, def.options.to[0])) {
        return error.Invalid;
    }

    const fields = std.json.parseFromSliceLeaky(Value, arena, got.document, .{}) catch {
        return error.Invalid;
    };
    const held: Value = if (fields == .object) fields.object.get(def.options.via) orelse
        .null else .null;
    const next = try moved(arena, held, try reference_is_many(ctx, def), parent, move);
    var change: std.json.ObjectMap = .empty;

    change.put(arena, def.options.via, next) catch return error.OutOfMemory;

    const document = std.json.Stringify.valueAlloc(arena, Value{ .object = change }, .{}) catch {
        return error.OutOfMemory;
    };

    // Saved in its current status: a live child joins or leaves at once, not as a pending
    // change waiting for its own publish; a draft stays a draft.
    _ = try registry.SDK.dispatch(ctx, records.Save, .{
        .id = child,
        .document = document,
        .status = got.record.status,
    });
}

/// The reference after the move: one id set or cleared, or the parent added to or taken
/// out of many.
fn moved(
    arena: std.mem.Allocator,
    held: Value,
    many: bool,
    parent: []const u8,
    move: Move,
) Error!Value {
    std.debug.assert(parent.len > 0);

    if (!many) {
        return switch (move) {
            .join => .{ .string = parent },
            .leave => .null,
        };
    }

    var items = std.json.Array.init(arena);

    if (held == .array) {
        for (held.array.items) |item| {
            const is_parent = item == .string and std.mem.eql(u8, item.string, parent);

            if (!is_parent) {
                items.append(item) catch return error.OutOfMemory;
            }
        }
    }

    if (move == .join) {
        items.append(.{ .string = parent }) catch return error.OutOfMemory;
    }

    return .{ .array = items };
}

fn reference_is_many(ctx: *Ctx, def: model.field.Def) Error!bool {
    std.debug.assert(def.options.to.len == 1);

    const row = try records.domain.definition.find(ctx, def.options.to[0]) orelse {
        return error.Invalid;
    };

    for (row.def.fields) |field| {
        if (std.mem.eql(u8, field.name, def.options.via)) {
            return field.many;
        }
    }

    return error.Invalid;
}

/// The ids of the records pointing at the parent as the editor sees them: `kept` order
/// first, the rest by id (the order they were made).
pub fn members(
    ctx: *Ctx,
    granted: *const Grant,
    parent: []const u8,
    def: model.field.Def,
    kept: ?Value,
) Error![]const []const u8 {
    std.debug.assert(parent.len > 0);
    std.debug.assert(is_referenced_by(def));

    const arena = ctx.arena;
    const values = records.domain.values;
    const pointing = try values.referrers(ctx.db, arena, parent, .editing);
    var found: std.ArrayList([]const u8) = .empty;

    for (pointing) |referrer| {
        const same_field = std.mem.eql(u8, referrer.field, def.options.via);

        if (!same_field or contains(found.items, referrer.record_id)) {
            continue;
        }

        const room = found.items.len < members_max;

        if (room and try points_here(ctx, granted, referrer.record_id, def, parent)) {
            found.append(arena, referrer.record_id) catch return error.OutOfMemory;
        }
    }

    return ordered(arena, found.items, kept);
}

/// Whether the child, as its editor sees it, is of the field's type and points here.
fn points_here(
    ctx: *Ctx,
    granted: *const Grant,
    child: []const u8,
    def: model.field.Def,
    parent: []const u8,
) Error!bool {
    std.debug.assert(child.len > 0);
    std.debug.assert(parent.len > 0);

    const got = records.domain.crud.get(ctx, granted, child, .edit, null) catch |err| {
        return switch (err) {
            error.NotFound, error.Denied => false,
            else => err,
        };
    };

    if (!std.mem.eql(u8, got.record.type, def.options.to[0])) {
        return false;
    }

    const fields = std.json.parseFromSliceLeaky(Value, ctx.arena, got.document, .{}) catch {
        return false;
    };

    if (fields != .object) {
        return false;
    }

    return switch (fields.object.get(def.options.via) orelse .null) {
        .string => |id| std.mem.eql(u8, id, parent),
        .array => |ids| holds(ids.items, parent),
        else => false,
    };
}

fn ordered(
    arena: std.mem.Allocator,
    found: []const []const u8,
    kept: ?Value,
) Error![]const []const u8 {
    std.debug.assert(found.len <= members_max);

    var result: std.ArrayList([]const u8) = .empty;

    if (kept != null and kept.? == .array) {
        for (kept.?.array.items) |item| {
            const listed = item == .string and contains(found, item.string);

            if (listed and !contains(result.items, item.string)) {
                result.append(arena, item.string) catch return error.OutOfMemory;
            }
        }
    }

    var rest: std.ArrayList([]const u8) = .empty;

    for (found) |id| {
        if (!contains(result.items, id)) {
            rest.append(arena, id) catch return error.OutOfMemory;
        }
    }

    std.mem.sort([]const u8, rest.items, {}, by_text);
    result.appendSlice(arena, rest.items) catch return error.OutOfMemory;

    return result.items;
}

fn by_text(_: void, left: []const u8, right: []const u8) bool {
    std.debug.assert(left.len > 0);

    return std.mem.order(u8, left, right) == .lt;
}

fn ids_of(arena: std.mem.Allocator, wanted: Value) Error![]const []const u8 {
    std.debug.assert(members_max > 0);

    var ids: std.ArrayList([]const u8) = .empty;

    if (wanted != .array) {
        return ids.items;
    }

    for (wanted.array.items) |item| {
        if (item == .string and item.string.len > 0 and !contains(ids.items, item.string)) {
            ids.append(arena, item.string) catch return error.OutOfMemory;
        }
    }

    if (ids.items.len > members_max) {
        return error.Invalid;
    }

    return ids.items;
}

fn ids_value(arena: std.mem.Allocator, ids: []const []const u8) Error!Value {
    std.debug.assert(ids.len <= members_max);

    var items = std.json.Array.init(arena);

    for (ids) |id| {
        items.append(.{ .string = id }) catch return error.OutOfMemory;
    }

    return .{ .array = items };
}

fn holds(items: []const Value, id: []const u8) bool {
    std.debug.assert(id.len > 0);

    for (items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, id)) {
            return true;
        }
    }

    return false;
}

fn contains(ids: []const []const u8, id: []const u8) bool {
    std.debug.assert(id.len > 0);

    for (ids) |known| {
        if (std.mem.eql(u8, known, id)) {
            return true;
        }
    }

    return false;
}

fn is_referenced_by(def: model.field.Def) bool {
    std.debug.assert(def.name.len > 0);

    return model.field.is_virtual(def.kind) and def.options.to.len == 1 and
        def.options.via.len > 0;
}

fn has_virtual(fields: []const model.field.Def) bool {
    std.debug.assert(fields.len < 1 << 16);

    for (fields) |def| {
        if (is_referenced_by(def)) {
            return true;
        }
    }

    return false;
}
