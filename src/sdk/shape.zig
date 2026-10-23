const std = @import("std");

pub const Error = error{ShapeMismatch};

const sample_len_max: u32 = 4 << 10;
const answer_len_max: u32 = 64 << 10;

/// The documented output and the real one, compared the way documentation can promise:
/// the same fields present, the same optionals set, lists empty or not together, flags and
/// enums equal. Ids, clocks, counts and generated text differ every run and are not
/// compared, and neither are list elements: a documented list is a sample, not a census,
/// and its element fields are already enforced by parsing the answer into `Out`.
pub fn same(documented: anytype, actual: @TypeOf(documented)) Error!void {
    const Value = @TypeOf(documented);

    comptime std.debug.assert(@typeInfo(Value) != .@"fn");
    comptime std.debug.assert(@typeInfo(Value) != .@"opaque");

    switch (@typeInfo(Value)) {
        .@"struct" => |info| {
            inline for (info.fields) |field| {
                try same(@field(documented, field.name), @field(actual, field.name));
            }
        },
        .optional => {
            if ((documented == null) != (actual == null)) {
                return Error.ShapeMismatch;
            }

            if (documented != null) {
                try same(documented.?, actual.?);
            }
        },
        .pointer => |info| {
            try same_pointer(info, documented, actual);
        },
        .bool, .@"enum" => {
            if (documented != actual) {
                return Error.ShapeMismatch;
            }
        },
        else => {},
    }
}

fn same_pointer(
    comptime info: std.builtin.Type.Pointer,
    documented: anytype,
    actual: @TypeOf(documented),
) Error!void {
    comptime std.debug.assert(info.size == .slice or info.size == .one);

    if (info.size != .slice) {
        return;
    }

    std.debug.assert(documented.len <= sample_len_max);
    std.debug.assert(actual.len <= answer_len_max);

    if ((documented.len == 0) != (actual.len == 0)) {
        return Error.ShapeMismatch;
    }
}

/// `same`, for answers known only as JSON (an installed plugin's): every documented field
/// present, null where it is null, lists empty or not together, flags equal. Text, numbers
/// and list elements are not compared.
pub fn same_json(documented: std.json.Value, actual: std.json.Value) Error!void {
    std.debug.assert(@intFromEnum(documented) <= @intFromEnum(std.json.Value.object));

    switch (documented) {
        .object => |fields| {
            if (actual != .object) {
                return Error.ShapeMismatch;
            }

            var each = fields.iterator();

            while (each.next()) |field| {
                const found = actual.object.get(field.key_ptr.*) orelse {
                    return if (field.value_ptr.* == .null) {} else Error.ShapeMismatch;
                };

                try same_json(field.value_ptr.*, found);
            }
        },
        .null => if (actual != .null) return Error.ShapeMismatch,
        .array => |items| {
            if (actual != .array or (items.items.len == 0) != (actual.array.items.len == 0)) {
                return Error.ShapeMismatch;
            }
        },
        .bool => |flag| {
            if (actual != .bool or actual.bool != flag) {
                return Error.ShapeMismatch;
            }
        },
        else => if (actual == .null) return Error.ShapeMismatch,
    }
}

test "matching shapes pass, differing optionals and flags fail" {
    const Out = struct {
        id: []const u8,
        live: bool,
        note: ?[]const u8,
    };

    try same(Out{
        .id = "abc",
        .live = true,
        .note = "x",
    }, .{
        .id = "zz",
        .live = true,
        .note = "other",
    });

    try std.testing.expectError(Error.ShapeMismatch, same(
        Out{
            .id = "abc",
            .live = true,
            .note = "x",
        },
        .{
            .id = "zz",
            .live = true,
            .note = null,
        },
    ));
    try std.testing.expectError(Error.ShapeMismatch, same(
        Out{
            .id = "abc",
            .live = true,
            .note = null,
        },
        .{
            .id = "zz",
            .live = false,
            .note = null,
        },
    ));
}

test "a documented list is a sample: only emptiness is promised" {
    const Out = struct {
        tags: []const []const u8,
        title: []const u8,
    };

    try same(Out{
        .tags = &.{"a"},
        .title = "Hello",
    }, .{
        .tags = &.{"b"},
        .title = "Other",
    });
    try same(Out{
        .tags = &.{"a"},
        .title = "Hello",
    }, .{
        .tags = &.{ "b", "c", "d" },
        .title = "Other",
    });

    try std.testing.expectError(Error.ShapeMismatch, same(
        Out{
            .tags = &.{"a"},
            .title = "Hello",
        },
        .{
            .tags = &.{},
            .title = "Other",
        },
    ));
    try std.testing.expectError(Error.ShapeMismatch, same(
        Out{
            .tags = &.{"a"},
            .title = "Hello",
        },
        .{
            .tags = &.{"b"},
            .title = "",
        },
    ));
}

test "JSON answers compared by shape" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const documented = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{ "id": "a", "live": true, "note": null, "tags": ["x"] }
    , .{});
    const same_shape = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{ "id": "zz", "live": true, "tags": ["y", "z"], "more": 1 }
    , .{});
    const other_flag = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{ "id": "zz", "live": false, "note": null, "tags": ["y"] }
    , .{});

    try same_json(documented, same_shape);
    try std.testing.expectError(Error.ShapeMismatch, same_json(documented, other_flag));
}
