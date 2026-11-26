//! A plugin's description of how one of its types is laid out (`sdk/plugin/shape_wire.zig`),
//! read and checked once before any value is read or built by it (`described_parser.zig`).
//! Nothing a plugin says is trusted: every size, offset, count and name is checked, the
//! nesting and the number of parts are bounded. A part may name one it is inside of (a tree's
//! node its children) only where it lies at an address of its own, so a value is never
//! inside itself; how deep a value's addresses are followed is bounded where it is read
//! (`given.zig`).
const std = @import("std");
const parser = @import("described_parser.zig");

pub const Error = error{ Invalid, OutOfMemory };

/// How long a description may be, how many parts it may say, and how deep they may nest.
pub const text_bytes_max: u32 = 1 << 20;
pub const nodes_max: u32 = 4096;
pub const depth_max: u32 = 64;

pub const Kind = enum {
    int,
    float,
    bool,
    text,
    /// A value whose shape comes with the data (`publr/free_value.zig`): its bytes' address
    /// and length, as a text's.
    free,
    enumeration,
    list,
    /// The address of one value.
    pointer,
    optional,
    object,
    /// A union: nothing in the block, its alternative and its payload's address beside it.
    choice,
};

pub const Node = struct {
    kind: Kind,
    /// The bytes of an int, a float or an enum; of an optional's payload; of one item of a
    /// list; of a pointer's target; of an object.
    size: u32 = 0,
    signed: bool = false,
    /// An int that is a decimal's units: how many places, and JSON writes it as its text.
    decimal: bool = false,
    places: u8 = 0,
    /// An optional with no byte of its own: its payload's address is zero for none.
    niche: bool = false,
    /// A list of pairs that JSON writes as an object keyed by each pair's first field.
    keyed: bool = false,
    /// An object that JSON writes as an array of its fields.
    tuple: bool = false,
    /// An object that JSON writes as its first field alone.
    lone: bool = false,
    /// Whether a walk of a value of this part meets a union.
    choosy: bool = false,
    alignment: u8 = 1,
    /// An optional's payload, a list's item, a pointer's target.
    child: u32 = 0,
    /// An object's fields, a union's alternatives, an enum's tags: where they begin and how
    /// many.
    first: u32 = 0,
    count: u32 = 0,
};

pub const Field = struct {
    name: []const u8,
    offset: u32 = 0,
    /// The field's default as JSON; empty for none.
    default: []const u8 = "",
    node: u32,
    /// A union's alternative: the bytes its payload takes, and how they are aligned.
    size: u32 = 0,
    alignment: u8 = 1,
};

pub const Tag = struct {
    name: []const u8,
    value: i64,
};

pub const Described = struct {
    /// The description as the plugin wrote it.
    text: []const u8,
    nodes: []const Node,
    fields: []const Field,
    tags: []const Tag,

    /// The root is node 0.
    pub const root: u32 = 0;

    /// How many bytes of the block a value of `node` takes where it lies.
    pub fn span(described: *const Described, node: u32) u32 {
        std.debug.assert(node < described.nodes.len);

        const found = described.nodes[node];

        return switch (found.kind) {
            .int, .float, .enumeration, .object => found.size,
            .bool => 1,
            .text, .list, .free => 8,
            .pointer => 4,
            .choice => 0,
            .optional => if (found.niche) described.span(found.child) else found.size + 1,
        };
    }

    pub fn fields_of(described: *const Described, node: u32) []const Field {
        const found = described.nodes[node];

        std.debug.assert(found.kind == .object);

        return described.fields[found.first..][0..found.count];
    }

    pub fn alternatives_of(described: *const Described, node: u32) []const Field {
        const found = described.nodes[node];

        std.debug.assert(found.kind == .choice);

        return described.fields[found.first..][0..found.count];
    }

    pub fn tags_of(described: *const Described, node: u32) []const Tag {
        const found = described.nodes[node];

        std.debug.assert(found.kind == .enumeration);

        return described.tags[found.first..][0..found.count];
    }

    /// Which field of object `node` (or alternative of union `node`) is named `name`,
    /// looked for at `guess` first: two builds of one type agree on the order.
    pub fn field_named(
        described: *const Described,
        node: u32,
        name: []const u8,
        guess: u32,
    ) ?u32 {
        const found = described.nodes[node];
        const fields = described.fields[found.first..][0..found.count];

        std.debug.assert(found.kind == .object or found.kind == .choice);

        if (guess < fields.len and std.mem.eql(u8, fields[guess].name, name)) {
            return guess;
        }

        for (fields, 0..) |field, index| {
            if (std.mem.eql(u8, field.name, name)) {
                return @intCast(index);
            }
        }

        return null;
    }
};

/// `text` read and checked; its parts are in `arena`, their names in `text` itself.
pub fn parse(arena: std.mem.Allocator, text: []const u8) Error!Described {
    if (text.len == 0 or text.len > text_bytes_max) {
        return error.Invalid;
    }

    std.debug.assert(text.len <= text_bytes_max);

    return parser.parse(arena, text);
}

/// For tests of what is built: whether every byte of `block` that no part of the root's
/// value lies on is zero (the padding between fields, the room of an optional holding
/// nothing is checked by the test itself).
pub fn padding_is_zero(described: *const Described, block: []const u8) !bool {
    const covered = try std.testing.allocator.alloc(bool, block.len);
    defer std.testing.allocator.free(covered);

    std.debug.assert(block.len >= described.span(Described.root));

    @memset(covered, false);
    cover(described, Described.root, 0, covered);

    for (block, covered) |byte, on| {
        if (!on and byte != 0) {
            return false;
        }
    }

    return true;
}

fn cover(described: *const Described, node: u32, at: u32, covered: []bool) void {
    const found = described.nodes[node];

    std.debug.assert(at + described.span(node) <= covered.len);

    switch (found.kind) {
        .object => for (described.fields_of(node)) |field| {
            cover(described, field.node, at + field.offset, covered);
        },
        .optional => {
            cover(described, found.child, at, covered);

            if (!found.niche) {
                covered[at + found.size] = true;
            }
        },
        else => @memset(covered[at..][0..described.span(node)], true),
    }
}
