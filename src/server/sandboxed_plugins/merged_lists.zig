//! The lists of a merge (`merged.zig`): the written list laid over the kept one item by
//! item, by each item's `id`, or, for a keyed list, by each pair's key.
const std = @import("std");
const id_map = @import("../../sdk/plugin/id_map.zig");
const given_module = @import("given.zig");
const laid_module = @import("laid.zig");
const merged = @import("merged.zig");
const scalars = @import("transfer_scalars.zig");

const Given = given_module.Given;
const Layout = laid_module.Layout;
const Source = merged.Source;
const Error = merged.Error;

pub fn merge(layout: *Layout, to: u32, at: u32, held: Source, wrote: Source) Error!void {
    const want = layout.described.nodes[to];
    const over = wrote.said();

    std.debug.assert(want.kind == .list);

    if (over.kind == .free or (over.kind == .object and !over.tuple and want.keyed)) {
        return merged.through_trees(layout, to, at, held, wrote);
    }

    if (over.kind != .list) {
        return wrote.moved(layout, to, at);
    }

    if (over.keyed != want.keyed) {
        return merged.through_trees(layout, to, at, held, wrote);
    }

    const kept = try held.given.items(held.node, held.bytes);
    const written = try wrote.given.items(wrote.node, wrote.bytes);

    try held.given.enter();
    defer held.given.leave();
    try wrote.given.enter();
    defer wrote.given.leave();

    const lists: Lists = .{
        .held = held,
        .wrote = wrote,
        .kept = kept,
        .written = written,
    };

    if (want.keyed) {
        return merge_keyed(layout, to, at, lists);
    }

    const by_id = try lists.all_written_have_ids();

    if (!by_id and kept.count == written.count) {
        const where = try layout.items(to, at, kept.count);

        for (0..kept.count) |index| {
            const position: u32 = @intCast(index);

            try merged.merge(
                layout,
                want.child,
                where + want.size * position,
                lists.kept_at(position),
                lists.written_at(position),
            );
        }

        return;
    }

    return merge_by_id(layout, to, at, lists, by_id);
}

/// The two lists of one merge, their items copied out.
const Lists = struct {
    held: Source,
    wrote: Source,
    kept: Given.Items,
    written: Given.Items,

    fn kept_at(lists: Lists, index: u32) Source {
        std.debug.assert(index < lists.kept.count);

        return lists.held.inside(lists.held.said().child, lists.kept.at(index));
    }

    fn written_at(lists: Lists, index: u32) Source {
        std.debug.assert(index < lists.written.count);

        return lists.wrote.inside(lists.wrote.said().child, lists.written.at(index));
    }

    /// Whether the modifier wrote at least one item and every one carries a text `id`.
    fn all_written_have_ids(lists: Lists) Error!bool {
        std.debug.assert(lists.written.count <= given_module.items_max);

        for (0..lists.written.count) |index| {
            if (try id_of(lists.written_at(@intCast(index))) == null) {
                return false;
            }
        }

        return lists.written.count > 0;
    }
};

/// The written list, each item laid over the kept one of the same id; one with no kept item
/// of its id is new.
fn merge_by_id(layout: *Layout, to: u32, at: u32, lists: Lists, by_id: bool) Error!void {
    const want = layout.described.nodes[to];
    const scratch = layout.scratch;
    var places: id_map.Map(u32) = .empty;

    std.debug.assert(want.kind == .list and !want.keyed);

    if (by_id) {
        places.ensureTotalCapacity(scratch, lists.kept.count) catch return error.OutOfMemory;

        for (0..lists.kept.count) |index| {
            const id = try id_of(lists.kept_at(@intCast(index))) orelse continue;
            const entry = places.getOrPutAssumeCapacity(id);

            // The first of two with the same id.
            if (!entry.found_existing) {
                entry.value_ptr.* = @intCast(index);
            }
        }
    }

    const where = try layout.items(to, at, lists.written.count);

    for (0..lists.written.count) |index| {
        const position: u32 = @intCast(index);
        const after = lists.written_at(position);
        const slot = where + want.size * position;
        const place = if (by_id) places.get((try id_of(after)).?) else null;

        if (place) |found| {
            try merged.merge(layout, want.child, slot, lists.kept_at(found), after);
        } else {
            try after.moved(layout, want.child, slot);
        }
    }
}

/// A keyed list: each kept pair, laid over by the written one of the same key, then the
/// written pairs whose key is new.
fn merge_keyed(layout: *Layout, to: u32, at: u32, lists: Lists) Error!void {
    const want = layout.described.nodes[to];
    const scratch = layout.scratch;
    const pair = layout.described.fields_of(want.child);
    const own = lists.held.given.described.fields_of(lists.held.said().child);
    const other = lists.wrote.given.described.fields_of(lists.wrote.said().child);
    var places: id_map.Map(u32) = .empty;
    var fresh: u32 = 0;

    std.debug.assert(want.keyed and pair.len == 2);
    std.debug.assert(own.len == 2 and other.len == 2);

    const taken = scratch.alloc(bool, lists.written.count) catch return error.OutOfMemory;

    places.ensureTotalCapacity(scratch, lists.written.count) catch return error.OutOfMemory;
    @memset(taken, false);

    for (0..lists.written.count) |index| {
        const pair_bytes = lists.written.at(@intCast(index));
        const key = try lists.wrote.given.text(pair_bytes[other[0].offset..]);

        places.putAssumeCapacity(key, @intCast(index));
    }

    for (0..lists.kept.count) |index| {
        const key = try lists.held.given.text(lists.kept.at(@intCast(index))[own[0].offset..]);

        if (places.get(key)) |found| {
            taken[found] = true;
        }
    }

    for (taken) |was| {
        fresh += @intFromBool(!was);
    }

    const where = try layout.items(to, at, @as(u64, lists.kept.count) + fresh);
    var next: u32 = 0;

    for (0..lists.kept.count) |index| {
        const before = lists.kept_at(@intCast(index));
        const key = try before.given.text(before.bytes[own[0].offset..]);
        const slot = where + want.size * next;
        const value = before.inside(own[1].node, before.bytes[own[1].offset..]);

        next += 1;
        try layout.text(slot + pair[0].offset, key);

        if (places.get(key)) |found| {
            const after = lists.written_at(found);
            const over = after.inside(other[1].node, after.bytes[other[1].offset..]);

            try merged.merge(layout, pair[1].node, slot + pair[1].offset, value, over);
        } else {
            try value.moved(layout, pair[1].node, slot + pair[1].offset);
        }
    }

    for (taken, 0..) |was, index| {
        if (!was) {
            const after = lists.written_at(@intCast(index));
            const slot = where + want.size * next;
            const over = after.inside(other[1].node, after.bytes[other[1].offset..]);

            next += 1;
            const key = try after.given.text(after.bytes[other[0].offset..]);

            try layout.text(slot + pair[0].offset, key);
            try over.moved(layout, pair[1].node, slot + pair[1].offset);
        }
    }
}

/// The text `id` of an item that is a struct holding one; null for any other item.
fn id_of(source: Source) Error!?[]const u8 {
    var found = source;

    std.debug.assert(source.bytes.len >= source.given.described.span(source.node));

    if (found.said().kind == .optional) {
        if (!found.given.present(found.node, found.bytes)) {
            return null;
        }

        found = found.inside(found.said().child, found.bytes);
    }

    const said = found.said();

    if (said.kind != .object or said.tuple or said.lone) {
        return null;
    }

    const index = found.given.described.field_named(found.node, "id", 0) orelse return null;
    const field = found.given.described.fields_of(found.node)[index];
    var id = found.inside(field.node, found.bytes[field.offset..]);

    if (id.said().kind == .optional) {
        if (!id.given.present(id.node, id.bytes)) {
            return null;
        }

        id = id.inside(id.said().child, id.bytes);
    }

    return switch (id.said().kind) {
        .text, .enumeration => try scalars.name_of(id.given, id.node, id.bytes),
        .int => if (id.said().decimal) try scalars.name_of(id.given, id.node, id.bytes) else null,
        else => null,
    };
}
