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

/// The children a virtual field holds for one record, at most: the ones its kept order
/// names first, then the rest in the order they were made. More are read with a query of
/// the children's type.
pub const children_max: u32 = 50;
/// Children read a page at a time while the ones a record shows are looked for.
const children_page: u32 = 200;

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

    for (found, documents) |record, *document| {
        if (!std.mem.eql(u8, record.type, type_handle)) {
            continue;
        }

        document.* = try placed(ctx, document.*, def, record.id, clauses);
    }
}

const Child = struct {
    id: []const u8,
    type: []const u8,
    fields: Value,
};

/// The children a record shows: of the field's type, pointing at `parent`, as the caller
/// may read them; the `kept` ones (the field's own order) first, then the rest oldest
/// first, `children_max` in all. Read a page at a time into the scratch: only the ones
/// shown are kept.
fn children_of(
    ctx: *Ctx,
    def: model.field.Def,
    parent: []const u8,
    kept: []const []const u8,
    clauses: []const []const u8,
) Error![]const Child {
    std.debug.assert(parent.len > 0);
    std.debug.assert(kept.len <= children_max);

    const arena = ctx.arena;
    const scratch = try ctx.scratch();
    const kept_found = try arena.alloc(?Child, kept.len);
    var rest: std.ArrayList(Child) = .empty;
    var kept_left: u32 = @intCast(kept.len);
    var offset: u32 = 0;

    @memset(kept_found, null);

    while (kept_left > 0 or rest.items.len < children_max - kept.len) {
        const begun = scratch.mark();
        defer scratch.rewind(begun);

        var paged = ctx.*;

        paged.arena = scratch.allocator();

        const listed = registry.SDK.dispatch(&paged, records.List, .{
            .type = def.options.to[0],
            .filter_field = def.options.via,
            .filter_values = &.{parent},
            .filters = clauses,
            .order = .created_asc,
            .limit = children_page,
            .offset = offset,
            .documents = true,
            .expand = false,
        }) catch |err| switch (err) {
            error.NotFound, error.Denied, error.Invalid => break,
            else => return err,
        };

        for (listed.records, listed.documents) |record, text| {
            const at = index_of(kept, record.id);
            const wanted = if (at) |index|
                kept_found[index] == null
            else
                rest.items.len < children_max - kept.len;

            if (!wanted) {
                continue;
            }

            const fields = std.json.parseFromSliceLeaky(Value, arena, text, .{
                .allocate = .alloc_always,
            }) catch continue;
            const child: Child = .{
                .id = try arena.dupe(u8, record.id),
                .type = try arena.dupe(u8, record.type),
                .fields = fields,
            };

            if (at) |index| {
                kept_found[index] = child;
                kept_left -= 1;
            } else {
                rest.append(arena, child) catch return error.OutOfMemory;
            }
        }

        if (listed.records.len < children_page) {
            break;
        }

        offset += children_page;
    }

    var shown: std.ArrayList(Child) = .empty;

    for (kept_found) |found| {
        if (found) |child| {
            shown.append(arena, child) catch return error.OutOfMemory;
        }
    }

    const room = children_max - @as(u32, @intCast(shown.items.len));

    shown.appendSlice(arena, rest.items[0..@min(rest.items.len, room)]) catch {
        return error.OutOfMemory;
    };

    std.debug.assert(shown.items.len <= children_max);

    return shown.items;
}

fn index_of(ids: []const []const u8, id: []const u8) ?u32 {
    std.debug.assert(id.len > 0);
    std.debug.assert(ids.len <= children_max);

    for (ids, 0..) |known, index| {
        if (std.mem.eql(u8, known, id)) {
            return @intCast(index);
        }
    }

    return null;
}

/// The document with the field's kept ids replaced by the children pointing at `parent`:
/// the kept order first, the rest after in the order they were made.
fn placed(
    ctx: *Ctx,
    text: []const u8,
    def: model.field.Def,
    parent: []const u8,
    clauses: []const []const u8,
) Error![]const u8 {
    std.debug.assert(parent.len > 0);
    std.debug.assert(def.options.via.len > 0);

    const arena = ctx.arena;
    var document = std.json.parseFromSliceLeaky(Value, arena, text, .{}) catch return text;

    if (document != .object) {
        return text;
    }

    var kept: std.ArrayList([]const u8) = .empty;

    if (document.object.get(def.name)) |held| {
        if (held == .array) {
            for (held.array.items) |item| {
                if (kept.items.len == children_max) {
                    break;
                }

                const fresh = item == .string and item.string.len > 0 and
                    index_of(kept.items, item.string) == null;

                if (fresh) {
                    kept.append(arena, item.string) catch return error.OutOfMemory;
                }
            }
        }
    }

    const children = try children_of(ctx, def, parent, kept.items, clauses);
    var items = std.json.Array.init(arena);

    for (children) |child| {
        items.append(try object_of(arena, child)) catch return error.OutOfMemory;
    }

    document.object.put(arena, def.name, .{
        .array = items,
    }) catch return error.OutOfMemory;

    return std.json.Stringify.valueAlloc(arena, document, .{}) catch error.OutOfMemory;
}

/// A child as its parent shows it: `_id`, `_type`, then its fields.
fn object_of(arena: std.mem.Allocator, child: Child) Error!Value {
    std.debug.assert(child.id.len > 0);

    var object: std.json.ObjectMap = .empty;

    object.put(arena, "_id", .{
        .string = child.id,
    }) catch return error.OutOfMemory;
    object.put(arena, "_type", .{
        .string = child.type,
    }) catch return error.OutOfMemory;

    if (child.fields == .object) {
        var entries = child.fields.object.iterator();

        while (entries.next()) |entry| {
            object.put(arena, entry.key_ptr.*, entry.value_ptr.*) catch return error.OutOfMemory;
        }
    }

    return .{
        .object = object,
    };
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
