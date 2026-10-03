//! Virtual fields, worked out when records are read (`record list` with documents, `record
//! get` for delivery): `referenced_by` puts in place of the ids it keeps the records of its
//! type whose reference points here, in the kept order, the ones not yet ordered after in
//! the order they were made. One list for a whole page of records, read as the caller with
//! the parent read's status and owner clauses; one level deep.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const records = @import("../record.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const Record = records.Record;
const Value = std.json.Value;

/// The children read for one virtual field of a page, at most.
pub const children_max: u32 = 10_000;

/// Each document's virtual fields worked out, in place. `clauses` are the parent read's
/// status and owner filters (`status:is:published`, `created:by:<id>`), kept for the
/// children so they read as their parents did.
pub fn expand(
    ctx: *Ctx,
    found: []const Record,
    documents: [][]const u8,
    clauses: []const []const u8,
) Error!void {
    std.debug.assert(found.len == documents.len);
    std.debug.assert(found.len <= records.list_max);

    var done: std.StringHashMapUnmanaged(void) = .empty;

    for (found) |record| {
        if (done.contains(record.type)) {
            continue;
        }

        done.put(ctx.arena, record.type, {}) catch return error.OutOfMemory;

        const row = try records.domain.definition.find(ctx, record.type) orelse continue;

        for (row.def.fields) |def| {
            if (model.field.is_virtual(def.kind) and def.options.to.len == 1) {
                try expand_field(ctx, record.type, def, found, documents, clauses);
            }
        }
    }
}

/// One virtual field over the page's records of one type.
fn expand_field(
    ctx: *Ctx,
    type_handle: []const u8,
    def: model.field.Def,
    found: []const Record,
    documents: [][]const u8,
    clauses: []const []const u8,
) Error!void {
    std.debug.assert(model.field.is_virtual(def.kind));
    std.debug.assert(type_handle.len > 0);

    const arena = ctx.arena;
    var parents: std.ArrayList([]const u8) = .empty;

    for (found) |record| {
        if (std.mem.eql(u8, record.type, type_handle)) {
            parents.append(arena, record.id) catch return error.OutOfMemory;
        }
    }

    const children = try children_of(ctx, def, parents.items, clauses);

    for (found, documents) |record, *document| {
        if (!std.mem.eql(u8, record.type, type_handle)) {
            continue;
        }

        document.* = try placed(arena, document.*, def, record.id, children);
    }
}

const Child = struct { id: []const u8, type: []const u8, fields: Value };

/// The records of the field's type whose reference points at one of `parents`, as the
/// caller may read them.
fn children_of(
    ctx: *Ctx,
    def: model.field.Def,
    parents: []const []const u8,
    clauses: []const []const u8,
) Error![]const Child {
    std.debug.assert(parents.len <= records.list_max);

    const arena = ctx.arena;
    var children: std.ArrayList(Child) = .empty;
    var offset: u32 = 0;

    while (children.items.len < children_max) {
        const listed = registry.SDK.dispatch(ctx, records.List, .{
            .type = def.options.to[0],
            .filter_field = def.options.via,
            .filter_values = parents,
            .filters = clauses,
            .order = .created_desc,
            .limit = records.list_max,
            .offset = offset,
            .documents = true,
            .expand = false,
        }) catch |err| switch (err) {
            error.NotFound, error.Denied, error.Invalid => return children.items,
            else => return err,
        };

        for (listed.records, listed.documents) |record, text| {
            const fields = std.json.parseFromSliceLeaky(Value, arena, text, .{}) catch continue;

            children.append(arena, .{
                .id = record.id,
                .type = record.type,
                .fields = fields,
            }) catch return error.OutOfMemory;
        }

        if (listed.records.len < records.list_max) {
            break;
        }

        offset += records.list_max;
    }

    return children.items;
}

/// The document with the field's kept ids replaced by the children pointing at `parent`:
/// the kept order first, the rest after by id (the order they were made).
fn placed(
    arena: std.mem.Allocator,
    text: []const u8,
    def: model.field.Def,
    parent: []const u8,
    children: []const Child,
) Error![]const u8 {
    std.debug.assert(parent.len > 0);
    std.debug.assert(def.options.via.len > 0);

    var document = std.json.parseFromSliceLeaky(Value, arena, text, .{}) catch return text;

    if (document != .object) {
        return text;
    }

    const kept = document.object.get(def.name);
    var ordered: std.ArrayList(Child) = .empty;

    if (kept != null and kept.? == .array) {
        for (kept.?.array.items) |item| {
            if (item != .string) {
                continue;
            }

            for (children) |child| {
                if (std.mem.eql(u8, child.id, item.string) and points_at(child, def, parent)) {
                    ordered.append(arena, child) catch return error.OutOfMemory;
                }
            }
        }
    }

    var rest: std.ArrayList(Child) = .empty;

    for (children) |child| {
        if (points_at(child, def, parent) and !listed_in(ordered.items, child.id)) {
            rest.append(arena, child) catch return error.OutOfMemory;
        }
    }

    std.mem.sort(Child, rest.items, {}, by_id);
    ordered.appendSlice(arena, rest.items) catch return error.OutOfMemory;

    var items = std.json.Array.init(arena);

    for (ordered.items) |child| {
        items.append(try object_of(arena, child)) catch return error.OutOfMemory;
    }

    document.object.put(arena, def.name, .{ .array = items }) catch return error.OutOfMemory;

    return std.json.Stringify.valueAlloc(arena, document, .{}) catch error.OutOfMemory;
}

/// Whether the child's reference holds the parent: the one id, or one of many.
fn points_at(child: Child, def: model.field.Def, parent: []const u8) bool {
    std.debug.assert(parent.len > 0);

    if (child.fields != .object) {
        return false;
    }

    const held = child.fields.object.get(def.options.via) orelse return false;

    return switch (held) {
        .string => |id| std.mem.eql(u8, id, parent),
        .array => |ids| holds_id(ids.items, parent),
        else => false,
    };
}

fn holds_id(items: []const Value, id: []const u8) bool {
    std.debug.assert(id.len > 0);

    for (items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, id)) {
            return true;
        }
    }

    return false;
}

fn listed_in(children: []const Child, id: []const u8) bool {
    std.debug.assert(id.len > 0);

    for (children) |child| {
        if (std.mem.eql(u8, child.id, id)) {
            return true;
        }
    }

    return false;
}

fn by_id(_: void, left: Child, right: Child) bool {
    std.debug.assert(left.id.len > 0);

    return std.mem.order(u8, left.id, right.id) == .lt;
}

/// A child as its parent shows it: `_id`, `_type`, then its fields.
fn object_of(arena: std.mem.Allocator, child: Child) Error!Value {
    std.debug.assert(child.id.len > 0);

    var object: std.json.ObjectMap = .empty;

    object.put(arena, "_id", .{ .string = child.id }) catch return error.OutOfMemory;
    object.put(arena, "_type", .{ .string = child.type }) catch return error.OutOfMemory;

    if (child.fields == .object) {
        var entries = child.fields.object.iterator();

        while (entries.next()) |entry| {
            object.put(arena, entry.key_ptr.*, entry.value_ptr.*) catch return error.OutOfMemory;
        }
    }

    return .{ .object = object };
}

/// The clauses of a list a virtual field's children keep: its statuses and owner.
pub fn kept_clauses(
    arena: std.mem.Allocator,
    filters: []const []const u8,
) Error![]const []const u8 {
    std.debug.assert(filters.len <= 64 << 10);

    var kept: std.ArrayList([]const u8) = .empty;

    for (filters) |clause| {
        const status = std.mem.startsWith(u8, clause, "status:");
        const owner = std.mem.startsWith(u8, clause, "created:by:");

        if (status or owner) {
            kept.append(arena, clause) catch return error.OutOfMemory;
        }
    }

    return kept.items;
}
