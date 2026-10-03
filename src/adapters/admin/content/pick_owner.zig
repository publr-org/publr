//! The picker opened from a virtual field: records already here are left out, and a
//! record a single reference holds elsewhere names that record, for the confirmation
//! before it is moved here.

const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const record_operations = @import("../../../operations/record.zig");
const display = @import("../display.zig");

const Error = admin.Error;
const Session = admin.Session;
const Value = std.json.Value;
const Record = record_operations.Record;

/// Where a listed record sits now, by the opener's reference field.
pub const Owner = union(enum) {
    /// Not held anywhere, or held by a multiple reference: linking adds, asking nothing.
    free,
    /// Already listed here.
    here,
    /// Held by another record, named by its title.
    elsewhere: []const u8,
};

/// One owner per record: `via` read from each document, the others' titles in one read.
pub fn owners_of(
    session: *Session,
    found: []const Record,
    documents: []const []const u8,
    field: []const u8,
    via: []const u8,
    parent: []const u8,
) Error![]const Owner {
    std.debug.assert(found.len == documents.len);
    std.debug.assert(via.len > 0 and parent.len > 0);

    const arena = session.arena;
    const owners = try arena.alloc(Owner, found.len);
    const listed_here = try members_of(session, field, parent);
    var others: std.ArrayList([]const u8) = .empty;

    for (found, documents, owners) |record, text, *owner| {
        owner.* = .free;

        if (contains(listed_here, record.id)) {
            owner.* = .here;
            continue;
        }

        const fields = std.json.parseFromSliceLeaky(Value, arena, text, .{}) catch continue;
        const held = if (fields == .object) fields.object.get(via) orelse .null else Value.null;

        // Pointing here by its live value but not listed: taken out, pending; free again.
        if (held == .string and held.string.len > 0 and !std.mem.eql(u8, held.string, parent)) {
            owner.* = .{ .elsewhere = held.string };
            try others.append(arena, held.string);
        }
    }

    try name_others(session, owners, others.items);

    return owners;
}

/// Each `elsewhere` id replaced by that record's title (the id when it cannot be read).
fn name_others(session: *Session, owners: []Owner, ids: []const []const u8) Error!void {
    std.debug.assert(ids.len <= owners.len);

    if (ids.len == 0) {
        return;
    }

    const listed = registry.SDK.dispatch(&session.ctx, record_operations.List, .{
        .ids = ids,
        .limit = record_operations.list_max,
    }) catch return; // The ids stand in for titles the caller cannot read.
    const titles = try display.titles(&session.ctx, listed.records);

    for (owners) |*owner| {
        if (owner.* != .elsewhere) {
            continue;
        }

        for (listed.records, titles) |record, title| {
            if (std.mem.eql(u8, record.id, owner.elsewhere)) {
                owner.* = .{ .elsewhere = title };
            }
        }
    }
}

/// The ids the field lists now, as the parent's editor sees them.
fn members_of(
    session: *Session,
    field: []const u8,
    parent: []const u8,
) Error![]const []const u8 {
    std.debug.assert(parent.len > 0);

    var ids: std.ArrayList([]const u8) = .empty;
    const got = registry.SDK.dispatch(&session.ctx, record_operations.Get, .{
        .id = parent,
        .purpose = .edit,
    }) catch return ids.items;
    const document = std.json.parseFromSliceLeaky(Value, session.arena, got.document, .{}) catch {
        return ids.items;
    };
    const listed = if (document == .object) document.object.get(field) orelse .null else Value.null;

    if (listed != .array) {
        return ids.items;
    }

    for (listed.array.items) |item| {
        if (item == .string) {
            try ids.append(session.arena, item.string);
        }
    }

    return ids.items;
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
