//! Every size, offset and alignment of a layout core puts together itself
//! (`merged_shape.zig`): each struct's fields placed one after another, aligned as its
//! parts need, and the room each list, pointer and union says for what it holds.
const std = @import("std");
const described_module = @import("described.zig");

const Node = described_module.Node;
const Field = described_module.Field;
const Error = described_module.Error;

/// A size and how it is aligned.
const Room = struct {
    size: u32,
    alignment: u32,
};

const Rooms = struct {
    nodes: []Node,
    fields: []Field,
    /// Which structs have their fields placed.
    settled: []bool,
};

/// Every size, offset and alignment of what was built.
pub fn settle(arena: std.mem.Allocator, nodes: []Node, fields: []Field) Error!void {
    var rooms: Rooms = .{
        .nodes = nodes,
        .fields = fields,
        .settled = arena.alloc(bool, nodes.len) catch return error.OutOfMemory,
    };
    const builder = &rooms;
    const count = nodes.len;

    std.debug.assert(count > 0);

    @memset(builder.settled, false);

    for (0..count) |index| {
        _ = try room(builder, @intCast(index), 0);
    }

    for (builder.nodes, 0..) |*said, index| {
        switch (said.kind) {
            .list, .pointer => {
                const taken = try room(builder, said.child, 0);

                said.size = std.mem.alignForward(u32, taken.size, taken.alignment);
                said.alignment = @intCast(taken.alignment);
            },
            .choice => for (builder.fields[said.first..][0..said.count]) |*one| {
                const taken = try room(builder, one.node, 0);

                one.size = std.mem.alignForward(u32, taken.size, taken.alignment);
                one.alignment = @intCast(taken.alignment);
            },
            else => std.debug.assert(index < count),
        }
    }
}

/// The bytes part `index` takes where it lies, and how they are aligned; a struct's
/// fields are placed on the way, once.
fn room(builder: *Rooms, index: u32, depth: u32) Error!Room {
    const said = &builder.nodes[index];

    if (depth > described_module.depth_max) {
        return error.Invalid;
    }

    std.debug.assert(index < builder.nodes.len);

    switch (said.kind) {
        .bool => return .{
            .size = 1,
            .alignment = 1,
        },
        .int, .float, .enumeration => return .{
            .size = said.size,
            .alignment = @max(said.size, 1),
        },
        .text, .list, .free => return .{
            .size = 8,
            .alignment = 4,
        },
        .pointer => return .{
            .size = 4,
            .alignment = 4,
        },
        .choice => return .{
            .size = 0,
            .alignment = 1,
        },
        .optional => {
            const payload = try room(builder, said.child, depth + 1);

            said.size = payload.size;

            if (said.niche) {
                return payload;
            }

            return .{
                .size = payload.size + 1,
                .alignment = payload.alignment,
            };
        },
        .object => return object_room(builder, index, depth),
    }
}

fn object_room(builder: *Rooms, index: u32, depth: u32) Error!Room {
    const said = &builder.nodes[index];
    var cursor: u32 = 0;
    var alignment: u32 = 1;

    std.debug.assert(said.kind == .object);

    if (builder.settled[index]) {
        return .{
            .size = said.size,
            .alignment = said.alignment,
        };
    }

    for (builder.fields[said.first..][0..said.count]) |*field| {
        const taken = try room(builder, field.node, depth + 1);

        field.offset = std.mem.alignForward(u32, cursor, taken.alignment);
        cursor = field.offset + taken.size;
        alignment = @max(alignment, taken.alignment);
    }

    said.size = std.mem.alignForward(u32, cursor, alignment);
    said.alignment = @intCast(alignment);
    builder.settled[index] = true;

    return .{
        .size = said.size,
        .alignment = alignment,
    };
}
