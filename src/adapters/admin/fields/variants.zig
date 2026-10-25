//! A type's fields as the record form draws and reads them on a site with a dimension of
//! several values (languages): each field varying by it is followed by one field per
//! other value, named `name@language=pl`, so it is drawn, posted and read back like any
//! field. The editor shows
//! one variant at a time; an empty value shows the main one's text as its placeholder.
const std = @import("std");
const model = @import("../../../model.zig");

const Def = model.field.Def;
const Pair = model.dimension.Pair;
const Value = std.json.Value;

pub const Error = error{OutOfMemory};

/// `fields` with each varied field's values after it, for `others` (the dimension at each of
/// its other values).
/// A group or repeater that is not varied as a whole has its varied fields expanded inside;
/// one varied as a whole is a structure of its own per variant, inside which nothing more
/// varies. `document` gives each variant its placeholder (the main value), at the top level
/// and in groups.
pub fn expanded(
    arena: std.mem.Allocator,
    fields: []const Def,
    others: []const Pair,
    document: ?Value,
) Error![]const Def {
    std.debug.assert(fields.len <= model.field.fields_max);
    std.debug.assert(others.len <= 64);

    if (others.len == 0) {
        return fields;
    }

    var out: std.ArrayList(Def) = .empty;

    for (fields) |def| {
        const current = if (document) |doc| object_get(doc, def.name) else null;
        var own = def;

        const varied = others.len > 0 and
            model.dimension.varies_by(def.dimensions, others[0].dimension);

        if (model.field.is_container(def.kind) and !varied) {
            const inner = if (model.field.is_group(def.kind)) current else null;

            own.fields = try expanded(arena, def.fields, others, inner);
        }

        try out.append(arena, own);

        if (!varied) {
            continue;
        }

        for (others) |other| {
            try out.append(arena, try clone_of(arena, def, other, current));
        }
    }

    return out.items;
}

fn clone_of(arena: std.mem.Allocator, def: Def, other: Pair, main: ?Value) Error!Def {
    std.debug.assert(def.dimensions.len > 0);
    std.debug.assert(other.code.len > 0);

    var clone = def;

    clone.name = try model.dimension.key_of(arena, def.name, &.{other});
    clone.validation.required = false;
    clone.validation.unique = false;
    clone.locked = false;
    clone.dimensions = &.{};
    clone.default = "";
    clone.validation.items_min = null;

    if (main) |value| {
        if (value == .string and value.string.len > 0) {
            clone.options.placeholder = value.string;
        }
    }

    return clone;
}

fn object_get(value: Value, name: []const u8) ?Value {
    std.debug.assert(name.len > 0);

    return switch (value) {
        .object => |object| object.get(name),
        else => null,
    };
}

test "a varied field is followed by its variants; a group's varied fields inside it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const seo = [_]Def{
        .{
            .name = "title",
            .label = "Title",
            .kind = "string",
            .dimensions = &.{"language"},
        },
    };
    const fields = [_]Def{
        .{
            .validation = .{
                .required = true,
            },
            .name = "name",
            .label = "Name",
            .kind = "string",
            .dimensions = &.{"language"},
        },
        .{
            .name = "price",
            .label = "Price",
            .kind = "integer",
        },
        .{
            .name = "seo",
            .label = "SEO",
            .kind = "group",
            .fields = &seo,
        },
    };
    const document = try std.json.parseFromSliceLeaky(Value, arena, "{\"name\":\"Mug\"}", .{});
    const others = [_]Pair{
        .{
            .dimension = "language",
            .code = "pl",
        },
        .{
            .dimension = "language",
            .code = "de",
        },
    };
    const out = try expanded(arena, &fields, &others, document);

    try std.testing.expectEqual(@as(usize, 5), out.len);
    try std.testing.expectEqualStrings("name@language=pl", out[1].name);
    try std.testing.expect(!out[1].validation.required);
    try std.testing.expectEqualStrings("Mug", out[1].options.placeholder);
    try std.testing.expectEqualStrings("name@language=de", out[2].name);
    try std.testing.expectEqualStrings("title@language=pl", out[4].fields[1].name);
    try std.testing.expectEqual(fields.len, (try expanded(arena, &fields, &.{}, null)).len);
}
