//! A description written again from its parts (`described.zig`): one part of a layout a
//! plugin described, said on its own, and a layout core puts together itself
//! (`merged_shape.zig`). What is written is read and checked like any description before a
//! value is built by it.
const std = @import("std");
const described_module = @import("described.zig");
const shape_wire = @import("../../sdk/plugin/shape_wire.zig");

const Described = described_module.Described;

pub const Error = described_module.Error;

/// The description of `node` alone, in `arena`.
pub fn of(arena: std.mem.Allocator, described: *const Described, node: u32) Error![]const u8 {
    var writer: Writer = .{
        .arena = arena,
        .described = described,
    };

    std.debug.assert(node < described.nodes.len);

    try writer.part(node, false);

    std.debug.assert(writer.inside_len == 0);

    return writer.out.items;
}

/// `{ <name>: <node> }`: a struct of one field, `node` at its start.
pub fn wrapped(
    arena: std.mem.Allocator,
    described: *const Described,
    node: u32,
    comptime name: []const u8,
) Error![]const u8 {
    var writer: Writer = .{
        .arena = arena,
        .described = described,
    };
    const size = @max(described.span(node), 1);
    const head = comptime "o\x00" ++ shape_wire.word(0) ++ shape_wire.word(1) ++
        &[_]u8{name.len} ++ name ++ shape_wire.word(0) ++ shape_wire.word(0);

    std.debug.assert(node < described.nodes.len);

    try writer.bytes(head);
    std.mem.writeInt(u32, writer.out.items[2..6], size, .little);

    // The struct is one more a part inside may be said to be inside of.
    writer.inside[0] = described_module.nodes_max;
    writer.inside_len = 1;
    try writer.part(node, false);

    return writer.out.items;
}

const Writer = struct {
    arena: std.mem.Allocator,
    described: *const Described,
    out: std.ArrayList(u8) = .empty,
    /// The structs and unions being written, outermost first.
    inside: [described_module.depth_max]u32 = undefined,
    inside_len: u32 = 0,

    fn bytes(writer: *Writer, text: []const u8) Error!void {
        if (writer.out.items.len + text.len > described_module.text_bytes_max) {
            return error.Invalid;
        }

        std.debug.assert(text.len <= described_module.text_bytes_max);

        writer.out.appendSlice(writer.arena, text) catch return error.OutOfMemory;
    }

    fn word(writer: *Writer, value: u32) Error!void {
        var raw: [4]u8 = undefined;

        std.debug.assert(writer.out.items.len <= described_module.text_bytes_max);

        std.mem.writeInt(u32, &raw, value, .little);
        try writer.bytes(&raw);
    }

    fn name(writer: *Writer, text: []const u8) Error!void {
        if (text.len == 0 or text.len > std.math.maxInt(u8)) {
            return error.Invalid;
        }

        std.debug.assert(text.len <= std.math.maxInt(u8));

        try writer.bytes(&.{@intCast(text.len)});
        try writer.bytes(text);
    }

    /// Whether `node` is one being written: said as how far up it is.
    fn above(writer: *Writer, node: u32, addressed: bool) Error!bool {
        std.debug.assert(writer.inside_len <= described_module.depth_max);

        for (writer.inside[0..writer.inside_len], 0..) |outer, index| {
            if (outer == node) {
                if (!addressed) {
                    return error.Invalid;
                }

                try writer.bytes(&.{ 'r', @intCast(writer.inside_len - index) });

                return true;
            }
        }

        return false;
    }

    fn enter(writer: *Writer, node: u32) Error!void {
        if (writer.inside_len >= described_module.depth_max) {
            return error.Invalid;
        }

        std.debug.assert(node < writer.described.nodes.len);

        writer.inside[writer.inside_len] = node;
        writer.inside_len += 1;
    }

    fn part(writer: *Writer, node: u32, addressed: bool) Error!void {
        const said = writer.described.nodes[node];

        std.debug.assert(node < writer.described.nodes.len);

        if (try writer.above(node, addressed)) {
            return;
        }

        switch (said.kind) {
            .bool => try writer.bytes("b"),
            .text => try writer.bytes("s"),
            .free => try writer.bytes("v"),
            .int => if (said.decimal)
                try writer.bytes(&.{ 'd', said.places })
            else
                try writer.bytes(&.{ 'i', @intCast(said.size), @intFromBool(said.signed) }),
            .float => try writer.bytes(&.{ 'f', @intCast(said.size) }),
            .enumeration => try writer.tags(node),
            .list => {
                try writer.bytes(&.{ 'l', @intFromBool(said.keyed) });
                try writer.word(said.size);
                try writer.word(said.alignment);
                try writer.part(said.child, true);
            },
            .pointer => {
                try writer.bytes("p");
                try writer.word(said.size);
                try writer.word(said.alignment);
                try writer.part(said.child, true);
            },
            .optional => {
                try writer.bytes("n");
                try writer.word(said.size);
                try writer.bytes(&.{@intFromBool(said.niche)});
                try writer.part(said.child, false);
            },
            .object => try writer.object(node),
            .choice => try writer.choice(node),
        }
    }

    fn tags(writer: *Writer, node: u32) Error!void {
        const said = writer.described.nodes[node];

        std.debug.assert(said.kind == .enumeration);

        try writer.bytes(&.{ 'e', @intCast(said.size) });
        try writer.word(said.count);

        for (writer.described.tags_of(node)) |tag| {
            var raw: [8]u8 = undefined;

            std.mem.writeInt(i64, &raw, tag.value, .little);
            try writer.name(tag.name);
            try writer.bytes(&raw);
        }
    }

    fn object(writer: *Writer, node: u32) Error!void {
        const said = writer.described.nodes[node];
        const tuple: u8 = if (said.tuple) shape_wire.form_tuple else 0;
        const flags = tuple | (if (said.lone) shape_wire.form_lone else 0);

        std.debug.assert(said.kind == .object);

        try writer.bytes(&.{ 'o', flags });
        try writer.word(said.size);
        try writer.word(said.count);
        try writer.enter(node);

        for (writer.described.fields_of(node)) |field| {
            try writer.name(field.name);
            try writer.word(field.offset);
            try writer.word(@intCast(field.default.len));
            try writer.bytes(field.default);
            try writer.part(field.node, false);
        }

        writer.inside_len -= 1;
    }

    fn choice(writer: *Writer, node: u32) Error!void {
        const said = writer.described.nodes[node];

        std.debug.assert(said.kind == .choice);

        try writer.bytes("u");
        try writer.word(said.count);
        try writer.enter(node);

        for (writer.described.alternatives_of(node)) |alternative| {
            try writer.name(alternative.name);
            try writer.word(alternative.size);
            try writer.word(alternative.alignment);
            try writer.part(alternative.node, true);
        }

        writer.inside_len -= 1;
    }
};

test "a description written from its parts is the description it was read from" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Tree = struct {
        name: []const u8,
        children: []const @This() = &.{},
        next: ?*const @This() = null,
    };
    const Line = struct {
        title: []const u8,
        count: u32 = 2,
        kind: enum { item, step } = .step,
        note: ?[]const u8 = null,
        weight: ?f32 = null,
        tree: Tree,
        choice: union(enum) {
            none,
            count: u32,
            tree: Tree,
        },
        tags: []const []const u8 = &.{ "a", "b" },
    };
    const text = comptime shape_wire.describe(Line);
    const described = try described_module.parse(arena, text);

    try std.testing.expectEqualStrings(text, try of(arena, &described, Described.root));

    // One part on its own, and the same part as a struct's one field.
    const tree = described.fields_of(Described.root)[5].node;
    const alone = try of(arena, &described, tree);
    const inside = try wrapped(arena, &described, tree, "items");
    const again = try described_module.parse(arena, inside);

    try std.testing.expectEqualStrings(comptime shape_wire.describe(Tree), alone);
    try std.testing.expectEqualStrings("items", again.fields_of(Described.root)[0].name);
    try std.testing.expectEqual(described.span(tree), again.nodes[Described.root].size);
}
