//! What a modifier wrote laid over the value it was given, where both lie: no text between
//! them. The value keeps its own layout, with the fields only the modifier has beside its
//! own (`merged_shape.zig`); each part is built once, from the modifier's value where it
//! wrote one, else from the value as it was.
//!
//! The rules are the ones JSON was merged by. A struct takes each field the modifier wrote
//! and keeps the others. A list whose written items all carry a text `id` is the written
//! list, each item laid over the kept one of the same id, so a modifier may drop, reorder
//! or add items; another list of the same length is laid over item by item; a keyed list
//! (money) takes each written key and keeps the others. Anything else is replaced, read as
//! the value's own type. What cannot be (nothing, where the value must hold something; a
//! text where it holds a struct) ends the item as `Invalid`: its caller leaves that item
//! as it was.
//!
//! A part whose shape comes with the data, and an item that holds a union, are merged as
//! the trees they stand for (`merged_tree.zig`), read where they lie (`given_tree.zig`):
//! no text is written for them either.
const std = @import("std");
const free_json = @import("../../sdk/free_json.zig");
const free_value = @import("../../sdk/free_value.zig");
const described_module = @import("described.zig");
const given_module = @import("given.zig");
const given_tree = @import("given_tree.zig");
const laid_module = @import("laid.zig");
const merged_tree = @import("merged_tree.zig");
const merged_lists = @import("merged_lists.zig");
const transfer = @import("transfer.zig");

const Given = given_module.Given;
const Layout = laid_module.Layout;

pub const Error = error{ Invalid, OutOfMemory };

/// A value where it lies: which part of its description it is, and its bytes.
pub const Source = struct {
    given: *Given,
    node: u32,
    bytes: []const u8,

    pub fn said(source: Source) described_module.Node {
        std.debug.assert(source.node < source.given.described.nodes.len);

        return source.given.described.nodes[source.node];
    }

    pub fn inside(source: Source, node: u32, bytes: []const u8) Source {
        std.debug.assert(node < source.given.described.nodes.len);

        return .{
            .given = source.given,
            .node = node,
            .bytes = bytes,
        };
    }

    pub fn moved(source: Source, layout: *Layout, to: u32, at: u32) Error!void {
        return transfer.move(layout, to, at, source.given, source.node, source.bytes);
    }
};

/// One item of an apply built at `at` as `to` says: `held` with `wrote` laid over it.
pub fn item(layout: *Layout, to: u32, at: u32, held: Source, wrote: Source) Error!void {
    std.debug.assert(to < layout.described.nodes.len);

    // A union lies beside the block, met in the order of a walk: an item that holds one is
    // merged whole, as the tree it stands for.
    if (held.said().choosy or wrote.said().choosy) {
        return through_trees(layout, to, at, held, wrote);
    }

    return merge(layout, to, at, held, wrote);
}

pub fn merge(layout: *Layout, to: u32, at: u32, held: Source, wrote: Source) Error!void {
    const want = layout.described.nodes[to];
    const over = wrote.said();

    // The merged layout is the held value's own, part for part.
    if (want.kind != held.said().kind) {
        return error.Invalid;
    }

    if (over.kind == .pointer) {
        try wrote.given.enter();
        defer wrote.given.leave();

        const pointee = try wrote.given.pointee(wrote.node, wrote.bytes);

        return merge(layout, to, at, held, wrote.inside(over.child, pointee));
    }

    if (over.kind == .optional) {
        if (!wrote.given.present(wrote.node, wrote.bytes)) {
            return nothing(layout, to, at);
        }

        return merge(layout, to, at, held, wrote.inside(over.child, wrote.bytes));
    }

    std.debug.assert(over.kind != .pointer and over.kind != .optional);

    switch (want.kind) {
        .optional => {
            if (!held.given.present(held.node, held.bytes)) {
                return wrote.moved(layout, to, at);
            }

            layout.present(to, at);

            const payload = held.inside(held.said().child, held.bytes);

            return merge(layout, want.child, at, payload, wrote);
        },
        .pointer => {
            try held.given.enter();
            defer held.given.leave();

            const pointee = try held.given.pointee(held.node, held.bytes);
            const where = try layout.pointee(to, at);

            return merge(layout, want.child, where, held.inside(held.said().child, pointee), wrote);
        },
        .free => return free(layout, at, held, wrote),
        .int, .float, .bool, .text, .enumeration => return wrote.moved(layout, to, at),
        .list => return merged_lists.merge(layout, to, at, held, wrote),
        .object => return merge_object(layout, to, at, held, wrote),
        .choice => return error.Invalid,
    }
}

/// The modifier wrote nothing where the value lies: nothing it is, where the value may
/// hold nothing.
fn nothing(layout: *Layout, to: u32, at: u32) Error!void {
    const want = layout.described.nodes[to];

    std.debug.assert(to < layout.described.nodes.len);

    return switch (want.kind) {
        .optional => {},
        .free => layout.free(at, &.{@backingInt(free_value.Kind.null)}),
        else => error.Invalid,
    };
}

fn merge_object(layout: *Layout, to: u32, at: u32, held: Source, wrote: Source) Error!void {
    const want = layout.described.nodes[to];
    const over = wrote.said();

    std.debug.assert(want.kind == .object);

    // A reference lies as its id: replaced whole.
    if (want.lone) {
        return wrote.moved(layout, to, at);
    }

    // Written as its first field alone: that field is what lies over the value.
    if (over.kind == .object and over.lone) {
        const first = wrote.given.described.fields_of(wrote.node)[0];

        return merge(layout, to, at, held, wrote.inside(first.node, wrote.bytes[first.offset..]));
    }

    // A keyed list or a value whose shape comes with the data may hold the same fields.
    if (over.kind == .free or (over.kind == .list and over.keyed)) {
        return through_trees(layout, to, at, held, wrote);
    }

    if (over.kind != .object or over.tuple != want.tuple) {
        return wrote.moved(layout, to, at);
    }

    const kept = held.given.described.fields_of(held.node);
    const written = wrote.given.described.fields_of(wrote.node);

    if (want.tuple and written.len != kept.len) {
        return wrote.moved(layout, to, at);
    }

    for (layout.described.fields_of(to), 0..) |field, position| {
        const guess: u32 = @intCast(position);
        const where = at + field.offset;
        const own = if (want.tuple)
            guess
        else
            held.given.described.field_named(held.node, field.name, guess);
        const other = if (want.tuple)
            guess
        else
            wrote.given.described.field_named(wrote.node, field.name, guess);

        if (own) |index| {
            const before = held.inside(kept[index].node, held.bytes[kept[index].offset..]);

            if (other) |found| {
                const inside = wrote.bytes[written[found].offset..];
                const after = wrote.inside(written[found].node, inside);

                try merge(layout, field.node, where, before, after);
            } else {
                try before.moved(layout, field.node, where);
            }
        } else if (other) |found| {
            // A field only the modifier has: kept beside the value's own.
            const after = wrote.inside(written[found].node, wrote.bytes[written[found].offset..]);

            try after.moved(layout, field.node, where);
        } else {
            try layout.left_out(field, where);
        }
    }
}

/// A value whose shape comes with the data, with what the modifier wrote laid over it.
fn free(layout: *Layout, at: u32, held: Source, wrote: Source) Error!void {
    const scratch = layout.scratch;

    std.debug.assert(held.said().kind == .free);

    var target = try tree_of(scratch, held, .left_out);

    try merged_tree.overlay(scratch, &target, try tree_of(scratch, wrote, .null));

    return layout.free(at, (try free_json.from_tree(scratch, target)).bytes);
}

/// `held` and `wrote` merged as the trees they stand for, built at `at` as `to` says.
pub fn through_trees(layout: *Layout, to: u32, at: u32, held: Source, wrote: Source) Error!void {
    const scratch = layout.scratch;

    std.debug.assert(to < layout.described.nodes.len);

    var target = try tree_of(scratch, held, .left_out);

    try merged_tree.overlay(scratch, &target, try tree_of(scratch, wrote, .null));

    return layout.write(to, target, at);
}

/// The tree a value stands for: read where it lies when its shape comes with the data.
fn tree_of(
    scratch: std.mem.Allocator,
    source: Source,
    absent: given_module.Absent,
) Error!std.json.Value {
    std.debug.assert(source.bytes.len >= source.given.described.span(source.node));

    if (source.said().kind == .free) {
        return free_json.tree_of(scratch, .{
            .bytes = try source.given.free(source.bytes),
        });
    }

    return given_tree.of(source.given, source.node, source.bytes, absent);
}
