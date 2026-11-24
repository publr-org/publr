//! A struct written as JSON without the fields that hold their default: a reader filling
//! defaults (`std.json.parse`) reads it back the same. A manifest repeats small structs by
//! the thousand (a shape's nodes, an operation's fields), most fields at their default, so
//! writing only what differs keeps it a fraction of the size.
const std = @import("std");

/// Writes `value`'s fields, leaving out each that holds its declared default. Used as a
/// struct's `jsonStringify`.
pub fn write(value: anytype, writer: anytype) @TypeOf(writer.*).Error!void {
    const shape = @typeInfo(@TypeOf(value)).@"struct";

    comptime std.debug.assert(shape.field_names.len > 0);

    try writer.beginObject();

    inline for (shape.field_names, shape.field_types, shape.field_attrs) |name, Type, attrs| {
        if (!at_default(Type, attrs.defaultValue(Type), @field(value, name))) {
            try writer.objectField(name);
            try writer.write(@field(value, name));
        }
    }

    try writer.endObject();
}

/// Whether `held` is `field`'s default: only defaults a reader cannot mistake count (a
/// number, a flag, a tag, null, an empty list or text).
fn at_default(comptime Type: type, comptime declared: ?Type, held: Type) bool {
    const default = declared orelse return false;

    comptime std.debug.assert(@sizeOf(Type) > 0);

    return switch (@typeInfo(Type)) {
        .bool, .int, .float, .@"enum" => held == default,
        .optional => default == null and held == null,
        .pointer => |pointer| pointer.size == .slice and default.len == 0 and held.len == 0,
        else => false,
    };
}

const Sample = struct {
    parent: i32,
    name: []const u8 = "",
    optional: bool = false,
    required: bool = true,
    values: []const []const u8 = &.{},
    to: ?[]const u8 = null,

    pub fn jsonStringify(sample: Sample, writer: anytype) !void {
        return write(sample, writer);
    }
};

test "a struct is written without its defaults and read back the same" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const plain: Sample = .{
        .parent = 0,
    };
    const changed: Sample = .{
        .parent = 1,
        .name = "kind",
        .required = false,
        .values = &.{"a"},
        .to = "post",
    };

    const text = try std.json.Stringify.valueAlloc(arena, [_]Sample{ plain, changed }, .{});

    try std.testing.expectEqualStrings(
        \\[{"parent":0},{"parent":1,"name":"kind","required":false,"values":["a"],"to":"post"}]
    , text);

    const back = try std.json.parseFromSliceLeaky([]const Sample, arena, text, .{});

    try std.testing.expectEqual(@as(usize, 2), back.len);
    try std.testing.expect(back[0].required);
    try std.testing.expectEqualStrings("", back[0].name);
    try std.testing.expect(!back[1].required);
    try std.testing.expectEqualStrings("post", back[1].to.?);
}
