//! A struct of core's read out of an object a plugin handed over (`given_typed.zig`): each
//! field found by its name, one the plugin did not send at its default, a key per dimension
//! beside the operation's own fields gathered (`language: "pl"`).
const std = @import("std");
const dimension_input = @import("../../sdk/dimension_input.zig");
const given_module = @import("given.zig");
const given_typed = @import("given_typed.zig");

const Given = given_module.Given;
const Error = given_module.Error;

/// Which field of `Shape` is named `name`, looked for at `guess` first.
pub fn index_of(comptime Shape: type, name: []const u8, guess: u32) ?u32 {
    const names = comptime names_of(Shape);

    std.debug.assert(name.len > 0);

    if (guess < names.len and std.mem.eql(u8, names[guess], name)) {
        return guess;
    }

    for (names, 0..) |field_name, index| {
        if (std.mem.eql(u8, field_name, name)) {
            return @intCast(index);
        }
    }

    return null;
}

fn names_of(comptime Shape: type) []const []const u8 {
    comptime {
        const info = @typeInfo(Shape).@"struct";

        std.debug.assert(!info.is_tuple);

        var names: [info.field_names.len][]const u8 = undefined;

        for (info.field_names, &names) |name, *kept| {
            kept.* = name;
        }

        const kept = names;

        return &kept;
    }
}

/// Whether field `index` of `Shape` holds a value at run time.
pub fn carried(comptime Shape: type, comptime index: u32) bool {
    comptime {
        const info = @typeInfo(Shape).@"struct";

        std.debug.assert(index < info.field_names.len);

        return info.field_types[index] != void and !info.field_attrs[index].@"comptime";
    }
}

pub fn object_of(
    comptime Shape: type,
    given: *Given,
    node: u32,
    bytes: []const u8,
    options: given_typed.Options,
) Error!Shape {
    const info = @typeInfo(Shape).@"struct";
    const lifted = comptime dimension_input.field_of(Shape);
    var result: Shape = undefined;
    var found: [info.field_names.len]bool = @splat(false);
    var pairs: std.ArrayList(dimension_input.Pair) = .empty;

    if (given.described.nodes[node].kind != .object) {
        return error.Invalid;
    }

    for (given.described.fields_of(node), 0..) |field, position| {
        const inside = bytes[field.offset..];
        const index = index_of(Shape, field.name, @intCast(position)) orelse {
            // A key per dimension beside the operation's own fields (`language: "pl"`).
            if (lifted != null) {
                try pair_of(given, field, inside, &pairs);
            } else if (options.ignore_unknown) {
                try given.skip(field.node, inside);
            } else {
                return error.Invalid;
            }

            continue;
        };

        var taken = false;

        inline for (info.field_names, info.field_types, 0..) |name, Field, own| {
            if (comptime carried(Shape, own)) {
                if (index == own and !none_for(Field, given, field.node, inside)) {
                    const read = given_typed.read;

                    @field(result, name) = try read(Field, given, field.node, inside, options);
                    found[own] = true;
                    taken = true;
                }
            }
        }

        // What is not read is stepped over: its unions beside the block are passed.
        if (!taken) {
            try given.skip(field.node, inside);
        }
    }

    try defaults(Shape, &result, &found);

    if (lifted) |name| {
        try gathered(given, &@field(result, name), pairs.items);
    }

    return result;
}

/// Whether the field holds nothing where `Field` cannot say so: its default stands in.
fn none_for(comptime Field: type, given: *const Given, node: u32, bytes: []const u8) bool {
    std.debug.assert(node < given.described.nodes.len);

    if (@typeInfo(Field) == .optional or given.described.nodes[node].kind != .optional) {
        return false;
    }

    return !given.present(node, bytes);
}

/// A field the plugin did not send takes its default; one without a default is missed.
fn defaults(comptime Shape: type, result: *Shape, found: []const bool) Error!void {
    const info = @typeInfo(Shape).@"struct";

    std.debug.assert(found.len == info.field_names.len);

    inline for (info.field_names, info.field_types, 0..) |name, Field, own| {
        const attrs = info.field_attrs[own];

        if (comptime carried(Shape, own)) {
            if (!found[own]) {
                @field(result.*, name) = attrs.defaultValue(Field) orelse return error.Invalid;
            }
        } else if (comptime Field == void) {
            @field(result.*, name) = {};
        }
    }
}

fn pair_of(
    given: *Given,
    field: @import("described.zig").Field,
    bytes: []const u8,
    pairs: *std.ArrayList(dimension_input.Pair),
) Error!void {
    const code = try given_typed.read(?[]const u8, given, field.node, bytes, .{}) orelse return;

    std.debug.assert(field.name.len > 0);

    pairs.append(given.arena, .{
        .dimension = given.arena.dupe(u8, field.name) catch return error.OutOfMemory,
        .code = code,
    }) catch return error.OutOfMemory;
}

/// The dimensions named beside the operation's own fields, then those it was sent as one.
fn gathered(
    given: *Given,
    dimensions: *dimension_input.Dimensions,
    pairs: []const dimension_input.Pair,
) Error!void {
    const model_dimension = @import("../../model/dimension.zig");

    std.debug.assert(dimensions.pairs.len <= model_dimension.dimensions_max);

    if (pairs.len == 0) {
        return;
    }

    if (pairs.len + dimensions.pairs.len > model_dimension.dimensions_max) {
        return error.Invalid;
    }

    dimensions.pairs = std.mem.concat(given.arena, dimension_input.Pair, &.{
        pairs,
        dimensions.pairs,
    }) catch return error.OutOfMemory;
}
