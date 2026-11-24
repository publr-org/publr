//! The layout the values of an apply take once a modifier's answer lies over them
//! (`merged.zig`): the values' own, with each field only the modifier's type has added
//! beside the fields it lies among, so a later modifier reads what an earlier one added.
//! An added field may hold nothing: a value the modifier did not answer has none.
//!
//! The layout is core's own: every size and offset is worked out here, the description is
//! written from its parts (`described_text.zig`) and read back with every check a plugin's
//! description gets, so it is bounded as any other. A modifier whose type adds nothing
//! leaves the values' description as it is.
const std = @import("std");
const described_module = @import("described.zig");
const described_text = @import("described_text.zig");
const merged_added = @import("merged_added.zig");
const merged_rooms = @import("merged_rooms.zig");

const Described = described_module.Described;
const Node = described_module.Node;
const Field = described_module.Field;
const Tag = described_module.Tag;

pub const Error = described_module.Error;

/// The description of `{ items: [...] }` whose items are `held`'s part `kept` with the
/// fields only `wrote`'s part `written` has; null when it has none to add, or when the
/// two together are more than a description may say.
pub fn of(
    arena: std.mem.Allocator,
    held: *const Described,
    kept: u32,
    wrote: *const Described,
    written: u32,
    comptime field: []const u8,
) Error!?[]const u8 {
    var builder: Builder = .{
        .arena = arena,
        .held = held,
        .wrote = wrote,
    };

    std.debug.assert(kept < held.nodes.len);
    std.debug.assert(written < wrote.nodes.len);

    builder.root(kept, written, field) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return null,
    };

    if (builder.added == 0) {
        return null;
    }

    const built: Described = .{
        .text = "",
        .nodes = builder.nodes.items,
        .fields = builder.fields.items,
        .tags = builder.tags.items,
    };

    merged_rooms.settle(arena, builder.nodes.items, builder.fields.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return null,
    };

    const text = described_text.of(arena, &built, Described.root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return null,
    };

    // Read as any description is: one that does not pass is not used.
    _ = described_module.parse(arena, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return null,
    };

    return text;
}

/// A struct or union being built, and what it is built from.
pub const Outer = struct {
    from: u32,
    made: u32,
};

pub const Builder = struct {
    arena: std.mem.Allocator,
    held: *const Described,
    wrote: *const Described,
    nodes: std.ArrayList(Node) = .empty,
    fields: std.ArrayList(Field) = .empty,
    tags: std.ArrayList(Tag) = .empty,
    /// The held value's structs and unions being built, outermost first.
    inside: [described_module.depth_max]Outer = undefined,
    inside_len: u32 = 0,
    /// The same for a field copied from the modifier's type.
    copying: [described_module.depth_max]Outer = undefined,
    copying_len: u32 = 0,
    added: u32 = 0,

    fn root(builder: *Builder, kept: u32, written: u32, comptime field: []const u8) Error!void {
        const whole = try builder.node(.{
            .kind = .object,
            .first = 0,
            .count = 1,
        });
        const list = try builder.node(.{
            .kind = .list,
        });

        std.debug.assert(whole == Described.root);

        builder.fields.append(builder.arena, .{
            .name = field,
            .node = list,
        }) catch return error.OutOfMemory;
        const item = try builder.merged(kept, written);

        builder.nodes.items[list].child = item;
    }

    pub fn node(builder: *Builder, made: Node) Error!u32 {
        if (builder.nodes.items.len >= described_module.nodes_max) {
            return error.Invalid;
        }

        std.debug.assert(builder.nodes.items.len < described_module.nodes_max);

        builder.nodes.append(builder.arena, made) catch return error.OutOfMemory;

        return @intCast(builder.nodes.items.len - 1);
    }

    /// Room for `count` fields together: their own parts' fields come after them.
    pub fn fields_room(builder: *Builder, count: u32) Error!u32 {
        const first: u32 = @intCast(builder.fields.items.len);

        if (count > described_module.nodes_max - @min(first, described_module.nodes_max)) {
            return error.Invalid;
        }

        std.debug.assert(first <= described_module.nodes_max);

        builder.fields.appendNTimes(builder.arena, .{
            .name = "",
            .node = 0,
        }, count) catch return error.OutOfMemory;

        return first;
    }

    pub fn above(outer: []const Outer, from: u32) ?u32 {
        std.debug.assert(outer.len <= described_module.depth_max);

        for (outer) |one| {
            if (one.from == from) {
                return one.made;
            }
        }

        return null;
    }

    /// The modifier's part behind its pointers and optionals: what lies over a value.
    fn written_of(builder: *const Builder, written: ?u32) ?u32 {
        var found = written orelse return null;

        std.debug.assert(found < builder.wrote.nodes.len);

        for (0..described_module.depth_max) |_| {
            const said = builder.wrote.nodes[found];

            if (said.kind != .pointer and said.kind != .optional) {
                return found;
            }

            found = said.child;
        }

        return null;
    }

    /// The held value's part `kept`, with what `written` adds to it.
    fn merged(builder: *Builder, kept: u32, written: ?u32) Error!u32 {
        const said = builder.held.nodes[kept];
        const over = builder.written_of(written);

        std.debug.assert(kept < builder.held.nodes.len);

        if (above(builder.inside[0..builder.inside_len], kept)) |made| {
            return made;
        }

        const made = try builder.node(said);
        const other: ?Node = if (over) |index| builder.wrote.nodes[index] else null;

        switch (said.kind) {
            .int, .float, .bool, .text, .free => {},
            .enumeration => try builder.tags_of(made, builder.held, kept),
            .optional, .pointer => {
                const child = try builder.merged(said.child, over);

                builder.nodes.items[made].child = child;
            },
            .list => {
                const same = other != null and other.?.kind == .list and
                    other.?.keyed == said.keyed;
                const item = if (same) other.?.child else null;

                const child = if (said.keyed)
                    try builder.pair(said.child, item)
                else
                    try builder.merged(said.child, item);

                builder.nodes.items[made].child = child;
            },
            .object => try builder.object(made, kept, over),
            .choice => try builder.choice(made, kept, over),
        }

        return made;
    }

    pub fn tags_of(builder: *Builder, made: u32, from: *const Described, index: u32) Error!void {
        const first: u32 = @intCast(builder.tags.items.len);

        std.debug.assert(from.nodes[index].kind == .enumeration);

        builder.tags.appendSlice(builder.arena, from.tags_of(index)) catch {
            return error.OutOfMemory;
        };
        builder.nodes.items[made].first = first;
    }

    fn enter(builder: *Builder, from: u32, made: u32) Error!void {
        if (builder.inside_len >= described_module.depth_max) {
            return error.Invalid;
        }

        std.debug.assert(made < builder.nodes.items.len);

        builder.inside[builder.inside_len] = .{
            .from = from,
            .made = made,
        };
        builder.inside_len += 1;
    }

    /// A keyed list's pair: its key, and its value with what the written pair's adds.
    fn pair(builder: *Builder, kept: u32, written: ?u32) Error!u32 {
        const own = builder.held.fields_of(kept);
        const made = try builder.node(builder.held.nodes[kept]);
        const first = try builder.fields_room(2);
        const other = if (written) |index| builder.wrote.fields_of(index)[1].node else null;

        std.debug.assert(own.len == 2);

        try builder.enter(kept, made);
        builder.nodes.items[made].first = first;

        const key = try builder.merged(own[0].node, null);
        const value = try builder.merged(own[1].node, other);

        builder.fields.items[first] = own[0];
        builder.fields.items[first].node = key;
        builder.fields.items[first + 1] = own[1];
        builder.fields.items[first + 1].node = value;
        builder.inside_len -= 1;

        return made;
    }

    fn object(builder: *Builder, made: u32, kept: u32, written: ?u32) Error!void {
        const said = builder.held.nodes[kept];
        const own = builder.held.fields_of(kept);
        const other: []const Field = if (written) |index| blk: {
            const over = builder.wrote.nodes[index];
            const fits = over.kind == .object and !over.lone and over.tuple == said.tuple and
                (!said.tuple or over.count == said.count);

            break :blk if (fits and !said.lone) builder.wrote.fields_of(index) else &.{};
        } else &.{};
        const extra: u32 = if (said.tuple) 0 else @intCast(other.len);
        const first = try builder.fields_room(said.count + extra);
        var count = said.count;

        std.debug.assert(said.kind == .object);

        try builder.enter(kept, made);
        builder.nodes.items[made].first = first;

        for (own, 0..) |field, position| {
            const match: ?u32 = if (said.tuple and other.len > 0)
                other[position].node
            else
                named(other, field.name);

            const child = try builder.merged(field.node, match);

            builder.fields.items[first + position] = field;
            builder.fields.items[first + position].node = child;
        }

        builder.inside_len -= 1;

        for (other) |field| {
            if (said.tuple or named(own, field.name) != null) {
                continue;
            }

            const beside = try merged_added.beside(builder, field) orelse continue;

            builder.fields.items[first + count] = .{
                .name = field.name,
                .node = beside,
            };
            count += 1;
            builder.added += 1;
        }

        builder.nodes.items[made].count = count;
    }

    fn named(fields: []const Field, name: []const u8) ?u32 {
        std.debug.assert(name.len > 0);

        for (fields) |field| {
            if (std.mem.eql(u8, field.name, name)) {
                return field.node;
            }
        }

        return null;
    }

    fn choice(builder: *Builder, made: u32, kept: u32, written: ?u32) Error!void {
        const own = builder.held.alternatives_of(kept);
        const other: []const Field = if (written) |index|
            (if (builder.wrote.nodes[index].kind == .choice)
                builder.wrote.alternatives_of(index)
            else
                &.{})
        else
            &.{};
        const first = try builder.fields_room(@intCast(own.len));

        std.debug.assert(own.len > 0);

        try builder.enter(kept, made);
        builder.nodes.items[made].first = first;

        for (own, 0..) |alternative, position| {
            const child = try builder.merged(alternative.node, named(other, alternative.name));

            builder.fields.items[first + position] = alternative;
            builder.fields.items[first + position].node = child;
        }

        builder.inside_len -= 1;
    }
};

const shape_wire = @import("../../sdk/plugin/shape_wire.zig");

test {
    _ = merged_added;
    _ = merged_rooms;
}

test "a modifier's own fields are added beside the value's; one that adds none adds nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Tree = struct {
        name: []const u8,
        children: []const @This() = &.{},
    };
    const Owned = struct {
        id: []const u8,
        count: u8 = 0,
        inner: struct {
            on: bool,
        },
        lines: []const struct {
            id: []const u8,
        },
        tree: Tree,
    };
    const Wrote = struct {
        count: u32,
        grams: u64,
        note: ?[]const u8,
        inner: struct {
            level: i8,
            tree: Tree,
        },
        lines: []const struct {
            id: []const u8,
            ships: bool,
        },
    };
    const held = try described_module.parse(arena, comptime shape_wire.describe(Owned));
    const wrote = try described_module.parse(arena, comptime shape_wire.describe(Wrote));
    const text = (try of(arena, &held, 0, &wrote, 0, "items")).?;
    const merged = try described_module.parse(arena, text);
    const item = merged.nodes[merged.fields_of(0)[0].node].child;
    const fields = merged.fields_of(item);

    try std.testing.expectEqual(@as(usize, 7), fields.len);
    try std.testing.expectEqualStrings("tree", fields[4].name);
    try std.testing.expectEqualStrings("grams", fields[5].name);
    try std.testing.expectEqual(described_module.Kind.optional, merged.nodes[fields[5].node].kind);
    try std.testing.expectEqualStrings("note", fields[6].name);
    try std.testing.expect(merged.nodes[fields[6].node].niche);
    try std.testing.expectEqual(@as(u32, 1), merged.nodes[fields[1].node].size);

    const inner = merged.fields_of(fields[2].node);
    const line = merged.fields_of(merged.nodes[fields[3].node].child);

    try std.testing.expectEqual(@as(usize, 3), inner.len);
    try std.testing.expectEqualStrings("tree", inner[2].name);
    try std.testing.expectEqualStrings("ships", line[1].name);

    // The same type again, or one with fewer fields, adds nothing.
    try std.testing.expect(try of(arena, &held, 0, &held, 0, "items") == null);
    try std.testing.expect(try of(arena, &merged, item, &wrote, 0, "items") == null);
}
