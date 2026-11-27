//! What a read asks for in each of the site's dimensions, taken the way a caller says it: a
//! flag per dimension on the command line (`--language pl --variation b`), a key per
//! dimension in JSON (`{"language":"pl"}`). An operation takes it as a field of this type;
//! the operation checks the names against the site's dimensions.
const std = @import("std");
const model_dimension = @import("model/dimension.zig");

pub const Pair = model_dimension.Pair;

pub const Dimensions = struct {
    /// Each dimension asked for and its code; an empty code asks for its main value.
    pairs: []const Pair = &.{},

    /// Handed over as its pairs, each code keyed by its dimension.
    pub const publr_form = .keyed;

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
