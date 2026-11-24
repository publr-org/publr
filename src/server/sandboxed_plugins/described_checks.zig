//! What a description's parts must be to one another, checked once all are read: every
//! field inside its struct, every item inside the room its list says, a keyed list's item a
//! pair with a text first. A description that passes is walked without further checks.
const std = @import("std");
const described_module = @import("described.zig");

const Described = described_module.Described;
const Node = described_module.Node;
const Field = described_module.Field;
const Error = described_module.Error;

pub fn check(described: *const Described) Error!void {
    std.debug.assert(described.nodes.len > 0);
    std.debug.assert(described.nodes.len <= described_module.nodes_max);

    for (described.nodes, 0..) |node, index| {
        const fine = switch (node.kind) {
            .int, .float, .bool, .text, .free, .enumeration => true,
            .list => list_fits(described, node),
            .pointer => described.span(node.child) <= node.size,
            .optional => optional_fits(described, node),
            .object => object_fits(described, @intCast(index)),
            .choice => for (described.alternatives_of(@intCast(index))) |alternative| {
                if (described.span(alternative.node) > alternative.size) {
                    break false;
                }
            } else true,
        };

        if (!fine) {
            return error.Invalid;
        }
    }
}

fn list_fits(described: *const Described, list: Node) bool {
    std.debug.assert(list.kind == .list);

    if (described.span(list.child) > list.size) {
        return false;
    }

    if (!list.keyed) {
        return true;
    }

    const pair = described.nodes[list.child];

    if (pair.kind != .object or pair.tuple or pair.lone or pair.count != 2) {
        return false;
    }

    return described.nodes[described.fields_of(list.child)[0].node].kind == .text;
}

fn optional_fits(described: *const Described, optional: Node) bool {
    const payload = described.nodes[optional.child].kind;
    const span = described.span(optional.child);

    std.debug.assert(optional.kind == .optional);

    if (span > optional.size) {
        return false;
    }

    // Only an address can say none: a text's, a list's, a pointer's.
    if (optional.niche) {
        return payload == .text or payload == .list or payload == .pointer;
    }

    return true;
}

fn object_fits(described: *const Described, index: u32) bool {
    const object = described.nodes[index];

    std.debug.assert(object.kind == .object);

    for (described.fields_of(index)) |field| {
        if (@as(u64, field.offset) + described.span(field.node) > object.size) {
            return false;
        }
    }

    return !object.lone or object.count > 0;
}

/// Says of each part whether a walk of its value meets a union. A part may hold one it is
/// inside of, so the answer is carried up until nothing changes.
pub fn mark_choosy(nodes: []Node, fields: []const Field) void {
    std.debug.assert(nodes.len <= described_module.nodes_max);

    for (0..nodes.len + 1) |_| {
        var changed = false;

        for (nodes) |*node| {
            const meets = switch (node.kind) {
                .choice => true,
                .optional, .list, .pointer => nodes[node.child].choosy,
                .object => for (fields[node.first..][0..node.count]) |field| {
                    if (nodes[field.node].choosy) {
                        break true;
                    }
                } else false,
                else => false,
            };

            changed = changed or meets != node.choosy;
            node.choosy = meets;
        }

        if (!changed) {
            return;
        }
    }

    unreachable;
}

const shape_wire = @import("../../sdk/plugin/shape_wire.zig");

fn word_bytes(value: u32) [4]u8 {
    var bytes: [4]u8 = undefined;

    std.mem.writeInt(u32, &bytes, value, .little);

    return bytes;
}

test "a description is read into its parts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Line = struct {
        title: []const u8,
        count: u32 = 2,
        kind: enum { item, step } = .step,
        note: ?[]const u8 = null,
        weight: ?f32 = null,
        tags: []const []const u8 = &.{},
        only: enum { one } = .one,
        choice: union(enum) {
            none,
            count: u32,
        } = .none,
        children: []const @This() = &.{},
    };
    const described = try described_module.parse(arena, comptime shape_wire.describe(Line));
    const fields = described.fields_of(Described.root);

    try std.testing.expectEqual(@as(usize, 9), fields.len);
    try std.testing.expectEqualStrings("count", fields[1].name);
    try std.testing.expectEqualStrings("2", fields[1].default);
    try std.testing.expect(described.nodes[fields[2].node].kind == .enumeration);
    try std.testing.expectEqualStrings("step", described.tags_of(fields[2].node)[1].name);
    try std.testing.expect(described.nodes[fields[3].node].niche);
    try std.testing.expect(!described.nodes[fields[4].node].niche);
    try std.testing.expectEqual(@as(u32, 5), described.span(fields[4].node));
    try std.testing.expectEqual(@as(u32, 0), described.span(fields[6].node));
    try std.testing.expectEqual(@as(?u32, 5), described.field_named(0, "tags", 0));
    try std.testing.expect(described.field_named(0, "nope", 3) == null);

    // A union takes nothing in the block; a tree's children are the node itself, and every
    // part on the way to a union says so.
    try std.testing.expectEqual(@as(u32, 0), described.span(fields[7].node));
    try std.testing.expectEqualStrings("count", described.alternatives_of(fields[7].node)[1].name);
    try std.testing.expectEqual(Described.root, described.nodes[fields[8].node].child);
    try std.testing.expect(described.nodes[0].choosy and described.nodes[fields[8].node].choosy);
    try std.testing.expect(!described.nodes[fields[5].node].choosy);
}

test "a description that lies or is cut short is refused, never followed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parse = described_module.parse;
    const Pair = struct {
        name: []const u8,
        count: u64,
        choice: union(enum) {
            none,
            pair: struct {
                u8,
                bool,
            },
        },
    };
    const good = comptime shape_wire.describe(Pair);

    _ = try parse(arena, good);

    // Cut anywhere, or with bytes left over: refused.
    for (0..good.len) |len| {
        try std.testing.expectError(error.Invalid, parse(arena, good[0..len]));
    }

    try std.testing.expectError(error.Invalid, parse(arena, good ++ "b"));

    // A field that lies past its struct's end; an int of three bytes; an unknown kind.
    const head = "o\x00" ++ word_bytes(8) ++ word_bytes(1) ++ "\x01a";
    const past = head ++ word_bytes(4) ++ word_bytes(0) ++ "i\x08\x00";

    try std.testing.expectError(error.Invalid, parse(arena, past));
    try std.testing.expectError(error.Invalid, parse(arena, "i\x03\x00"));
    try std.testing.expectError(error.Invalid, parse(arena, "z"));

    // An offset near the top of a u32 does not wrap around its struct's size.
    const wraps = head ++ word_bytes(0xffff_fffc) ++ word_bytes(0) ++ "i\x08\x00";

    try std.testing.expectError(error.Invalid, parse(arena, wraps));

    // The same field twice; a list whose item is larger than it says; an enum with no tag;
    // an optional number said to need no byte of its own; a decimal of too many places.
    const field = "\x01a" ++ word_bytes(0) ++ word_bytes(0) ++ "b";
    const twice = "o\x00" ++ word_bytes(8) ++ word_bytes(2) ++ field ++ field;
    const small = "l\x00" ++ word_bytes(4) ++ word_bytes(4) ++ "i\x08\x00";
    const none = "e\x01" ++ word_bytes(0);
    const niche = "n" ++ word_bytes(8) ++ "\x01i\x08\x00";

    try std.testing.expectError(error.Invalid, parse(arena, twice));
    try std.testing.expectError(error.Invalid, parse(arena, small));
    try std.testing.expectError(error.Invalid, parse(arena, none));
    try std.testing.expectError(error.Invalid, parse(arena, niche));
    try std.testing.expectError(error.Invalid, parse(arena, "d\x13"));
    try std.testing.expectError(error.Invalid, parse(arena, ""));
}

test "a part inside itself, a keyed list of no pairs and a union that lies are refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parse = described_module.parse;
    const field = "\x01a" ++ word_bytes(0) ++ word_bytes(0);
    const room = word_bytes(8) ++ word_bytes(4);

    // A struct that is its own field, with or without an optional between, would never
    // end; so would one naming a part above the root.
    const own = "o\x00" ++ word_bytes(0) ++ word_bytes(1) ++ field ++ "r\x01";
    const optional = "o\x00" ++ word_bytes(9) ++ word_bytes(1) ++ field ++ "n" ++ word_bytes(8) ++
        "\x00r\x01";
    const above = "l\x00" ++ room ++ "r\x01";
    const fine = "o\x00" ++ word_bytes(8) ++ word_bytes(1) ++ field ++ "l\x00" ++ room ++ "r\x01";

    try std.testing.expectError(error.Invalid, parse(arena, own));
    try std.testing.expectError(error.Invalid, parse(arena, optional));
    try std.testing.expectError(error.Invalid, parse(arena, above));
    _ = try parse(arena, fine);

    // A keyed list's item is a pair whose first field is a text.
    const number = "\x01b" ++ word_bytes(8) ++ word_bytes(0) ++ "i\x08\x01";
    const pair = "o\x00" ++ word_bytes(16) ++ word_bytes(2) ++ field ++ "s" ++ number;
    const wrong = "o\x00" ++ word_bytes(16) ++ word_bytes(2) ++ field ++ "i\x08\x00" ++ number;
    const keyed = "l\x01" ++ word_bytes(16) ++ word_bytes(8);

    _ = try parse(arena, keyed ++ pair);
    try std.testing.expectError(error.Invalid, parse(arena, keyed ++ wrong));
    try std.testing.expectError(error.Invalid, parse(arena, keyed ++ "s"));
    try std.testing.expectError(error.Invalid, parse(arena, "l\x02" ++ room ++ "s"));

    // A union with no alternative, one named twice, a payload larger than its room.
    const alternative = "\x01a" ++ word_bytes(4) ++ word_bytes(4) ++ "i\x04\x00";
    const large = "\x01b" ++ word_bytes(4) ++ word_bytes(4) ++ "i\x08\x00";

    _ = try parse(arena, "u" ++ word_bytes(1) ++ alternative);
    try std.testing.expectError(error.Invalid, parse(arena, "u" ++ word_bytes(0)));
    try std.testing.expectError(error.Invalid, parse(arena, "u" ++ word_bytes(2) ++
        alternative ++ alternative));
    try std.testing.expectError(error.Invalid, parse(arena, "u" ++ word_bytes(1) ++ large));
}

test "nesting and the number of parts are bounded" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parse = described_module.parse;
    const level = "l\x00" ++ word_bytes(8) ++ word_bytes(4);
    var deep: std.ArrayList(u8) = .empty;

    for (0..described_module.depth_max) |_| {
        try deep.appendSlice(arena, level);
    }

    try deep.append(arena, 's');
    try std.testing.expectError(error.Invalid, parse(arena, deep.items));

    // One level less is the deepest a description goes.
    _ = try parse(arena, deep.items[level.len..]);

    // More parts than a description may say, however flat.
    var wide: std.ArrayList(u8) = .empty;

    try wide.appendSlice(arena, "o\x00" ++ word_bytes(1) ++ word_bytes(described_module.nodes_max));

    for (0..described_module.nodes_max) |index| {
        var name_buffer: [8]u8 = undefined;
        const field_name = try std.fmt.bufPrint(&name_buffer, "f{d}", .{index});

        try wide.append(arena, @intCast(field_name.len));
        try wide.appendSlice(arena, field_name);
        try wide.appendSlice(arena, &(word_bytes(0) ++ word_bytes(0)));
        try wide.append(arena, 'b');
    }

    try std.testing.expectError(error.Invalid, parse(arena, wide.items));
}
