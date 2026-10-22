//! The rules line under a field's help, in the viewer's language: the field's own
//! `validation.hint` with its bounds filled in, else one standard part per rule, joined.
const std = @import("std");
const admin = @import("../../admin.zig");
const model = @import("../../../model.zig");

const Def = model.field.Def;
const Placeholder = admin.Placeholder;
const hint_model = model.field.hint;

pub const separator = " · ";

/// Empty for a field with no rules to tell.
pub fn line(
    session: *const admin.Session,
    arena: std.mem.Allocator,
    def: Def,
) admin.Error![]const u8 {
    std.debug.assert(def.name.len > 0);
    std.debug.assert(def.validation.hint.len <= model.field.validation.hint_len_max);

    if (def.validation.hint.len > 0) {
        const values = try hint_model.values_of(arena, def);

        return session.translated(def.validation.hint, .{
            .values = try placeholders(arena, values),
        });
    }

    const parts = try hint_model.parts_of(arena, def);
    var text: std.ArrayList(u8) = .empty;

    for (parts.slice(), 0..) |part, index| {
        const told = try session.translated(
            part.template,
            .{
                .values = try placeholders(arena, part.named()),
            },
        );

        if (index > 0) {
            try text.appendSlice(arena, separator);
        }

        try text.appendSlice(arena, told);
    }

    return text.items;
}

fn placeholders(
    arena: std.mem.Allocator,
    values: []const hint_model.Value,
) admin.Error![]const Placeholder {
    std.debug.assert(values.len <= 16);

    const filled = try arena.alloc(Placeholder, values.len);

    for (values, filled) |value, *one| {
        one.* = .{
            .name = value.name,
            .value = value.value,
        };
    }

    std.debug.assert(filled.len == values.len);

    return filled;
}
