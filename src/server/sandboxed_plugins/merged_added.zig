//! A field only a modifier's type has, copied into the layout the values take once its
//! answer lies over them (`merged_shape.zig`): part for part as the modifier said it, and
//! as a field that may hold nothing.
const std = @import("std");
const described_module = @import("described.zig");
const merged_shape = @import("merged_shape.zig");

const Node = described_module.Node;
const Field = described_module.Field;
const Builder = merged_shape.Builder;
const Error = described_module.Error;

/// A field only the modifier's type has, copied as one that may hold nothing; null when
/// it cannot stand on its own (it holds a part it is inside of) or is too much to add.
pub fn beside(builder: *Builder, added: Field) Error!?u32 {
    const nodes_len = builder.nodes.items.len;
    const fields_len = builder.fields.items.len;
    const tags_len = builder.tags.items.len;
    const said = builder.wrote.nodes[added.node];

    std.debug.assert(builder.copying_len == 0);

    const made = optional_copy(builder, added.node, said) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => {
            builder.nodes.items.len = nodes_len;
            builder.fields.items.len = fields_len;
            builder.tags.items.len = tags_len;
            builder.copying_len = 0;

            return null;
        },
    };

    return made;
}

fn optional_copy(builder: *Builder, from: u32, said: Node) Error!u32 {
    std.debug.assert(from < builder.wrote.nodes.len);

    if (said.kind == .optional) {
        return copied(builder, from);
    }

    const wrapper = try builder.node(.{
        .kind = .optional,
        .niche = said.kind == .text or said.kind == .list or said.kind == .pointer,
    });

    const child = try copied(builder, from);

    builder.nodes.items[wrapper].child = child;

    return wrapper;
}

/// The modifier's part `from` as it is said, part for part.
fn copied(builder: *Builder, from: u32) Error!u32 {
    const said = builder.wrote.nodes[from];

    std.debug.assert(from < builder.wrote.nodes.len);

    if (Builder.above(builder.copying[0..builder.copying_len], from)) |made| {
        return made;
    }

    const made = try builder.node(said);

    switch (said.kind) {
        .int, .float, .bool, .text, .free => {},
        .enumeration => try builder.tags_of(made, builder.wrote, from),
        .optional, .pointer, .list => {
            const child = try copied_below(builder, from, said.child);

            builder.nodes.items[made].child = child;
        },
        .object, .choice => {
            const fields = builder.wrote.fields[said.first..][0..said.count];
            const first = try builder.fields_room(said.count);

            if (builder.copying_len >= described_module.depth_max) {
                return error.Invalid;
            }

            builder.copying[builder.copying_len] = .{
                .from = from,
                .made = made,
            };
            builder.copying_len += 1;
            builder.nodes.items[made].first = first;

            for (fields, 0..) |field, position| {
                const child = try copied_below(builder, from, field.node);

                builder.fields.items[first + position] = field;
                builder.fields.items[first + position].node = child;
            }

            builder.copying_len -= 1;
        },
    }

    return made;
}

/// A part below `from`. One said before `from` is a part `from` is inside of: copied
/// only when it is being copied too, else the field does not stand on its own.
fn copied_below(builder: *Builder, from: u32, child: u32) Error!u32 {
    std.debug.assert(child < builder.wrote.nodes.len);

    const outside = child <= from and
        Builder.above(builder.copying[0..builder.copying_len], child) == null;

    if (outside) {
        return error.Invalid;
    }

    return copied(builder, child);
}
