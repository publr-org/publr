//! What a read asks for in each of the site's dimensions, taken the way a caller says it: a
//! flag per dimension on the command line (`--language pl --variation b`), a key per
//! dimension in JSON (`{"language":"pl"}`). An operation takes it as a field of this type;
//! the adapters gather into it whatever is not one of the operation's own fields, and the
//! operation checks the names against the site's dimensions.
const std = @import("std");
const model_dimension = @import("../model/dimension.zig");

pub const Pair = model_dimension.Pair;

pub const Dimensions = struct {
    /// Each dimension asked for and its code; an empty code asks for its main value.
    pairs: []const Pair = &.{},

    /// From `{"language":"pl","variation":"b"}`.
    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!Dimensions {
        const value = try std.json.innerParse(std.json.Value, allocator, source, options);

        return from_value(allocator, value) catch error.UnexpectedToken;
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        value: std.json.Value,
        options: std.json.ParseOptions,
    ) std.json.ParseFromValueError!Dimensions {
        _ = options;

        return from_value(allocator, value) catch error.UnexpectedToken;
    }

    pub fn jsonStringify(dimensions: Dimensions, writer: anytype) !void {
        std.debug.assert(dimensions.pairs.len <= model_dimension.dimensions_max);

        try writer.beginObject();

        for (dimensions.pairs) |pair| {
            try writer.objectField(pair.dimension);
            try writer.write(pair.code);
        }

        try writer.endObject();
    }
};

fn from_value(allocator: std.mem.Allocator, value: std.json.Value) !Dimensions {
    if (value != .object) {
        return error.Invalid;
    }

    const object = value.object;

    if (object.count() > model_dimension.dimensions_max) {
        return error.Invalid;
    }

    const pairs = try allocator.alloc(Pair, object.count());
    var entries = object.iterator();
    var index: u32 = 0;

    while (entries.next()) |entry| : (index += 1) {
        if (entry.value_ptr.* != .string) {
            return error.Invalid;
        }

        pairs[index] = .{
            .dimension = entry.key_ptr.*,
            .code = entry.value_ptr.string,
        };
    }

    std.debug.assert(index == pairs.len);

    return .{
        .pairs = pairs,
    };
}

/// The name of `In`'s field of type `Dimensions`, if it has one.
pub fn field_of(comptime In: type) ?[]const u8 {
    comptime {
        std.debug.assert(@typeInfo(In) == .@"struct");

        for (std.meta.fields(In)) |field| {
            if (field.type == Dimensions) {
                return field.name;
            }
        }

        return null;
    }
}

/// `text`, a JSON object for `In`, with each top-level key that is none of `In`'s fields
/// moved under its `Dimensions` field: `{"id":"x","language":"pl"}` becomes
/// `{"id":"x","dimensions":{"language":"pl"}}`. As it is when `In` has no such field, or
/// `text` is not an object.
pub fn lift(comptime In: type, arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    std.debug.assert(text.len <= 64 << 20);

    const found = comptime field_of(In);

    if (found == null) {
        return text;
    }

    const target = comptime found.?;
    var value = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch {
        return text;
    };

    if (value != .object) {
        return text;
    }

    var gathered: std.json.ObjectMap = .empty;
    var kept: std.json.ObjectMap = .empty;
    var entries = value.object.iterator();

    while (entries.next()) |entry| {
        const own = own_field(In, entry.key_ptr.*);
        const map = if (own) &kept else &gathered;

        try map.put(arena, entry.key_ptr.*, entry.value_ptr.*);
    }

    if (gathered.count() == 0) {
        return text;
    }

    if (kept.get(target)) |given| {
        if (given == .object) {
            var named = given.object.iterator();

            while (named.next()) |entry| {
                try gathered.put(arena, entry.key_ptr.*, entry.value_ptr.*);
            }
        }
    }

    try kept.put(arena, target, .{
        .object = gathered,
    });
    value = .{
        .object = kept,
    };

    return std.json.Stringify.valueAlloc(arena, value, .{});
}

fn own_field(comptime In: type, name: []const u8) bool {
    std.debug.assert(name.len <= 64 << 10);

    inline for (std.meta.fields(In)) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            return true;
        }
    }

    return false;
}

test "a key per dimension: read, written, gathered from beside an operation's own fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const In = struct {
        id: []const u8,
        dimensions: Dimensions = .{},
    };
    const text = "{\"id\":\"r1\",\"language\":\"pl\",\"variation\":\"b\"}";
    const lifted = try lift(In, arena, text);
    const in = try std.json.parseFromSliceLeaky(In, arena, lifted, .{});

    try std.testing.expectEqualStrings("r1", in.id);
    try std.testing.expectEqual(@as(usize, 2), in.dimensions.pairs.len);

    const written = try std.json.Stringify.valueAlloc(arena, in.dimensions, .{});

    try std.testing.expect(std.mem.indexOf(u8, written, "\"language\":\"pl\"") != null);
    try std.testing.expectEqualStrings("{\"id\":\"r1\"}", try lift(In, arena, "{\"id\":\"r1\"}"));

    const Plain = struct {
        id: []const u8,
    };

    try std.testing.expectEqualStrings(text, try lift(Plain, arena, text));
    try std.testing.expectError(
        error.UnexpectedToken,
        std.json.parseFromSliceLeaky(In, arena, "{\"id\":\"r\",\"dimensions\":[1]}", .{}),
    );
}
