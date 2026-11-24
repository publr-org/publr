//! Reads a plugin's description of a layout into its parts, then checks every part against
//! the others once all are known (a part may name one that is still being read). What comes
//! out is safe to walk: every offset inside its struct, every item inside its list's room.
const std = @import("std");
const described_module = @import("described.zig");
const shape_wire = @import("../../sdk/plugin/shape_wire.zig");
const Reader = @import("described_reader.zig").Reader;

const Described = described_module.Described;
const Node = described_module.Node;
const Field = described_module.Field;
const Tag = described_module.Tag;
const Error = described_module.Error;

const nodes_max = described_module.nodes_max;
const depth_max = described_module.depth_max;

/// The most one struct or one list item may take, one field's default as JSON, and a
/// decimal's places.
const size_max: u32 = 1 << 24;
const default_bytes_max: u32 = 64 << 10;
const places_max: u8 = @import("../../model/decimal.zig").places_max;

/// The bytes a list's item, a pointer's target or a union's payload takes, and how they
/// are aligned.
const Room = struct {
    size: u32,
    alignment: u8,
};

const Parser = struct {
    arena: std.mem.Allocator,
    reader: Reader,
    nodes: std.ArrayList(Node) = .empty,
    fields: std.ArrayList(Field) = .empty,
    tags: std.ArrayList(Tag) = .empty,
    /// The structs and unions being read, outermost first: what `r` names.
    outer: [depth_max]u32 = undefined,
    outer_len: u32 = 0,

    /// One part and everything in it; where it is among the nodes. `addressed` when the part
    /// lies at an address of its own, where alone it may be one it is inside of.
    fn node(parser: *Parser, depth: u32, addressed: bool) Error!u32 {
        std.debug.assert(parser.nodes.items.len <= nodes_max);

        if (depth >= depth_max or parser.nodes.items.len >= nodes_max) {
            return error.Invalid;
        }

        const letter = try parser.reader.byte();

        if (letter == 'r') {
            const up = try parser.reader.byte();

            if (!addressed or up == 0 or up > parser.outer_len) {
                return error.Invalid;
            }

            return parser.outer[parser.outer_len - up];
        }

        const index: u32 = @intCast(parser.nodes.items.len);

        parser.nodes.append(parser.arena, .{
            .kind = .bool,
        }) catch return error.OutOfMemory;

        const made: Node = switch (letter) {
            'b' => .{
                .kind = .bool,
            },
            's' => .{
                .kind = .text,
            },
            'v' => .{
                .kind = .free,
            },
            'i' => try parser.int(),
            'd' => try parser.decimal(),
            'f' => try parser.float(),
            'e' => try parser.enumeration(),
            'l' => try parser.list(depth),
            'p' => try parser.pointer(depth),
            'n' => try parser.optional(depth),
            'o' => try parser.object(depth, index),
            'u' => try parser.choice(depth, index),
            else => return error.Invalid,
        };

        parser.nodes.items[index] = made;

        return index;
    }

    fn int(parser: *Parser) Error!Node {
        const size = try parser.reader.byte();
        const signed = try parser.reader.byte();

        if (!Reader.whole_size(size) or signed > 1) {
            return error.Invalid;
        }

        std.debug.assert(size <= 8);

        return .{
            .kind = .int,
            .size = size,
            .signed = signed == 1,
        };
    }

    fn decimal(parser: *Parser) Error!Node {
        const places = try parser.reader.byte();

        if (places > places_max) {
            return error.Invalid;
        }

        std.debug.assert(parser.reader.at <= parser.reader.text.len);

        return .{
            .kind = .int,
            .size = 8,
            .signed = true,
            .decimal = true,
            .places = places,
        };
    }

    fn float(parser: *Parser) Error!Node {
        const size = try parser.reader.byte();

        if (size != 4 and size != 8) {
            return error.Invalid;
        }

        std.debug.assert(parser.reader.at <= parser.reader.text.len);

        return .{
            .kind = .float,
            .size = size,
        };
    }

    fn enumeration(parser: *Parser) Error!Node {
        const size = try parser.reader.byte();
        const count = try parser.reader.word();
        const first: u32 = @intCast(parser.tags.items.len);

        // An enum of one tag takes no byte at all.
        const sized = Reader.whole_size(size) or (size == 0 and count == 1);

        if (!sized or count == 0 or count > nodes_max - @min(first, nodes_max)) {
            return error.Invalid;
        }

        for (0..count) |_| {
            const tag_name = try parser.reader.name();
            const raw = try parser.reader.take(8);

            parser.tags.append(parser.arena, .{
                .name = tag_name,
                .value = std.mem.readInt(i64, raw[0..8], .little),
            }) catch return error.OutOfMemory;
        }

        std.debug.assert(parser.tags.items.len == first + count);

        return .{
            .kind = .enumeration,
            .size = size,
            .first = first,
            .count = count,
        };
    }

    /// A size and an alignment, as a list's item and a pointer's target say them.
    fn room(parser: *Parser) Error!Room {
        const size = try parser.reader.word();
        const alignment = try parser.reader.word();
        const aligned = alignment <= 16 and (alignment == 0 or std.math.isPowerOfTwo(alignment));

        if (size > size_max or !aligned) {
            return error.Invalid;
        }

        std.debug.assert(alignment <= 16);

        return .{
            .size = size,
            .alignment = @intCast(@max(alignment, 1)),
        };
    }

    fn list(parser: *Parser, depth: u32) Error!Node {
        const keyed = try parser.reader.byte();
        const taken = try parser.room();
        const child = try parser.node(depth + 1, true);

        if (keyed > 1) {
            return error.Invalid;
        }

        std.debug.assert(child < parser.nodes.items.len);

        return .{
            .kind = .list,
            .size = taken.size,
            .alignment = taken.alignment,
            .keyed = keyed == 1,
            .child = child,
        };
    }

    fn pointer(parser: *Parser, depth: u32) Error!Node {
        const taken = try parser.room();
        const child = try parser.node(depth + 1, true);

        std.debug.assert(child < parser.nodes.items.len);

        return .{
            .kind = .pointer,
            .size = taken.size,
            .alignment = taken.alignment,
            .child = child,
        };
    }

    fn optional(parser: *Parser, depth: u32) Error!Node {
        const size = try parser.reader.word();
        const niche = try parser.reader.byte();
        const child = try parser.node(depth + 1, false);

        if (size > size_max or niche > 1) {
            return error.Invalid;
        }

        std.debug.assert(child < parser.nodes.items.len);

        return .{
            .kind = .optional,
            .size = size,
            .niche = niche == 1,
            .child = child,
        };
    }

    /// Room for `count` fields together: their own parts' fields come after them.
    fn fields_room(parser: *Parser, count: u32) Error!u32 {
        const first: u32 = @intCast(parser.fields.items.len);

        std.debug.assert(first <= nodes_max * 2);

        if (count > nodes_max - @min(first, nodes_max) or parser.outer_len >= depth_max) {
            return error.Invalid;
        }

        parser.fields.appendNTimes(parser.arena, undefined, count) catch {
            return error.OutOfMemory;
        };

        return first;
    }

    fn named_once(parser: *const Parser, earlier: []const Field, field_name: []const u8) bool {
        std.debug.assert(field_name.len > 0);
        std.debug.assert(earlier.len <= parser.fields.items.len);

        for (earlier) |field| {
            if (std.mem.eql(u8, field.name, field_name)) {
                return false;
            }
        }

        return true;
    }

    fn object(parser: *Parser, depth: u32, index: u32) Error!Node {
        const flags = try parser.reader.byte();
        const size = try parser.reader.word();
        const count = try parser.reader.word();
        const first = try parser.fields_room(count);
        const both = shape_wire.form_tuple | shape_wire.form_lone;

        if (size > size_max or flags >= both) {
            return error.Invalid;
        }

        std.debug.assert(parser.outer_len < depth_max);

        parser.outer[parser.outer_len] = index;
        parser.outer_len += 1;

        for (0..count) |position| {
            const field_name = try parser.reader.name();
            const offset = try parser.reader.word();
            const default_len = try parser.reader.word();

            if (default_len > default_bytes_max) {
                return error.Invalid;
            }

            const default = try parser.reader.take(default_len);
            const child = try parser.node(depth + 1, false);

            if (!parser.named_once(parser.fields.items[first..][0..position], field_name)) {
                return error.Invalid;
            }

            parser.fields.items[first + position] = .{
                .name = field_name,
                .offset = offset,
                .default = default,
                .node = child,
            };
        }

        parser.outer_len -= 1;

        return .{
            .kind = .object,
            .size = size,
            .tuple = flags == shape_wire.form_tuple,
            .lone = flags == shape_wire.form_lone,
            .first = first,
            .count = count,
        };
    }

    fn choice(parser: *Parser, depth: u32, index: u32) Error!Node {
        const count = try parser.reader.word();
        const first = try parser.fields_room(count);

        if (count == 0) {
            return error.Invalid;
        }

        std.debug.assert(parser.outer_len < depth_max);

        parser.outer[parser.outer_len] = index;
        parser.outer_len += 1;

        for (0..count) |position| {
            const alternative = try parser.reader.name();
            const taken = try parser.room();
            const child = try parser.node(depth + 1, true);

            if (!parser.named_once(parser.fields.items[first..][0..position], alternative)) {
                return error.Invalid;
            }

            parser.fields.items[first + position] = .{
                .name = alternative,
                .node = child,
                .size = taken.size,
                .alignment = taken.alignment,
            };
        }

        parser.outer_len -= 1;

        return .{
            .kind = .choice,
            .first = first,
            .count = count,
        };
    }
};

pub fn parse(arena: std.mem.Allocator, text: []const u8) Error!Described {
    var parser: Parser = .{
        .arena = arena,
        .reader = .{
            .text = text,
        },
    };
    const root = try parser.node(0, false);

    std.debug.assert(root == Described.root);

    // Bytes after the root say nothing: a description that carries them is not one.
    if (parser.reader.at != text.len) {
        return error.Invalid;
    }

    const described: Described = .{
        .text = text,
        .nodes = parser.nodes.items,
        .fields = parser.fields.items,
        .tags = parser.tags.items,
    };

    try @import("described_checks.zig").check(&described);
    @import("described_checks.zig").mark_choosy(parser.nodes.items, parser.fields.items);

    return described;
}
