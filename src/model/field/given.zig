//! A field's overrides as a plugin's code gives them (`publr/field_options.zig`), made into
//! core's own parts of `field.Def`: each member by its name, each enum by its tag, at every
//! level. Core's parts may change; where one stops matching the public shape by name, the
//! change says here how the public one maps onto it.
const std = @import("std");
const public = @import("../../publr/field_options.zig");
const options = @import("options.zig");
const validation = @import("validation.zig");
const field = @import("../field.zig");

/// The nesting a field's options reach: a group, its part, a list or an optional in it.
const depth_max: u32 = 8;

/// `value`, of the public shape, as core's `Target`.
pub fn converted(comptime Target: type, comptime value: anytype, comptime depth: u32) Target {
    comptime {
        const Source = @TypeOf(value);

        std.debug.assert(depth < depth_max);

        if (Source == Target) {
            return value;
        }

        return switch (@typeInfo(Target)) {
            .@"struct" => struct_of(Target, value, depth),
            .@"enum" => @field(Target, @tagName(value)),
            .optional => |optional| optional_of(optional.child, value, depth),
            .pointer => |pointer| slice_of(pointer.child, value, depth),
            else => value,
        };
    }
}

fn struct_of(comptime Target: type, comptime value: anytype, comptime depth: u32) Target {
    comptime {
        const Source = @TypeOf(value);
        var result: Target = .{};

        std.debug.assert(@typeInfo(Source) == .@"struct");
        std.debug.assert(std.meta.fieldNames(Source).len <= std.meta.fieldNames(Target).len);

        for (std.meta.fieldNames(Source)) |name| {
            const Field = @FieldType(Target, name);

            @field(result, name) = converted(Field, @field(value, name), depth + 1);
        }

        const done = result;

        return done;
    }
}

fn optional_of(comptime Child: type, comptime value: anytype, comptime depth: u32) ?Child {
    comptime {
        std.debug.assert(depth < depth_max);

        const held = value orelse return null;

        return converted(Child, held, depth + 1);
    }
}

fn slice_of(comptime Child: type, comptime value: anytype, comptime depth: u32) []const Child {
    comptime {
        std.debug.assert(depth < depth_max);
        std.debug.assert(value.len <= field.choices_max);

        var items: [value.len]Child = undefined;

        for (value, &items) |each, *item| {
            item.* = converted(Child, each, depth + 1);
        }

        const done = items;

        return &done;
    }
}

fn json_of(arena: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, value, .{});
}

test "the public defaults are core's defaults" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const shown = comptime converted(options.Options, public.Options{}, 0);
    const rules = comptime converted(validation.Validation, public.Validation{}, 0);
    const readers = comptime converted(field.Visibility, public.Visibility{}, 0);

    try std.testing.expectEqualStrings(try json_of(arena, options.Options{}), try json_of(
        arena,
        shown,
    ));
    try std.testing.expectEqualStrings(try json_of(arena, validation.Validation{}), try json_of(
        arena,
        rules,
    ));
    try std.testing.expectEqualStrings(try json_of(arena, field.Visibility{}), try json_of(
        arena,
        readers,
    ));
    try std.testing.expect(shown.reference.create and shown.media.link);
    try std.testing.expect(!rules.required);
}

test "a part given in the public shape reads the same in core's" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const given: public.Options = .{
        .step = 2,
        .richtext = .{
            .formats = &.{ .bold, .link },
        },
        .number = .{
            .unit = "kg",
            .control = .slider,
        },
        .reference = .{
            .on_delete = .clear,
        },
    };
    const shown = comptime converted(options.Options, given, 0);
    const rules = comptime converted(validation.Validation, public.Validation{
        .preset = .digits,
        .max_len = 80,
        .url = .{
            .schemes = &.{"mailto"},
        },
    }, 0);

    try std.testing.expectEqualStrings(
        "{\"step\":2,\"richtext\":{\"formats\":[\"bold\",\"link\"]},\"number\":{\"unit\":\"kg\"," ++
            "\"control\":\"slider\"},\"reference\":{\"on_delete\":\"clear\"}}",
        try json_of(arena, shown),
    );
    try std.testing.expectEqual(validation.Preset.digits, rules.preset);
    try std.testing.expectEqualStrings("mailto", rules.url.schemes[0]);
    try std.testing.expect(comptime converted(?u32, @as(?u32, null), 0) == null);
}
