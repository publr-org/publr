//! An operation's answer copied whole into other memory: every text and list it holds, at
//! any depth, so the memory the operation worked in can be given back. For the answers a
//! compiled-in plugin gets from the operations it calls, which an installed plugin gets
//! copied into its own memory. Only a plain answer can be copied (`plain`): values, texts,
//! lists, optionals, structs and unions of those. One that points at something else (a
//! list's open rows, a function) is left where it is.
const std = @import("std");

/// How deep a type is followed while deciding: past it the type is taken as not plain.
const depth_max = 16;
/// The most parts of a type (fields, alternatives, what a list or an optional holds) looked
/// at while deciding: past it the type is taken as not plain, as one that holds itself is.
const parts_max = 4096;

/// Whether every part of `Value` can be copied by `copy`.
pub fn plain(comptime Value: type) bool {
    return comptime decided(Value);
}

/// Whether `Value` is plain and nothing it points at can be changed where it lies: every
/// text and list is constant. Whoever is handed one by pointer changes it only by writing
/// the value itself, so its own bytes say whether it was changed.
pub fn settled(comptime Value: type) bool {
    return comptime decided_as(Value, true);
}

fn decided(comptime Value: type) bool {
    return decided_as(Value, false);
}

fn decided_as(comptime Value: type, comptime constant: bool) bool {
    // Each part looked at is a call and at most one turn of a loop.
    @setEvalBranchQuota(parts_max * 8);

    var left: u32 = parts_max;
    const whole = plain_at(Value, 0, &left, constant);

    std.debug.assert(left <= parts_max);

    return whole;
}

fn plain_at(
    comptime Value: type,
    comptime depth: u32,
    comptime left: *u32,
    comptime constant: bool,
) bool {
    std.debug.assert(depth <= depth_max + 1);

    if (depth > depth_max or left.* == 0) {
        return false;
    }

    left.* -= 1;

    return switch (@typeInfo(Value)) {
        .bool, .int, .float, .@"enum", .void => true,
        .optional => |info| plain_at(info.child, depth + 1, left, constant),
        .array => |info| plain_at(info.child, depth + 1, left, constant),
        .pointer => |info| info.size == .slice and info.sentinel() == null and
            (info.attrs.@"const" or !constant) and plain_at(info.child, depth + 1, left, constant),
        .@"struct" => |info| fields: {
            if (info.layout == .@"packed") {
                break :fields true;
            }

            for (info.field_types) |Field| {
                if (!plain_at(Field, depth + 1, left, constant)) {
                    break :fields false;
                }
            }

            break :fields true;
        },
        .@"union" => |info| alternatives: {
            if (info.tag_type == null) {
                break :alternatives false;
            }

            for (info.field_types) |Field| {
                if (!plain_at(Field, depth + 1, left, constant)) {
                    break :alternatives false;
                }
            }

            break :alternatives true;
        },
        else => false,
    };
}

/// `value` with every text and list it holds copied into `arena`: nothing of the copy
/// points into the memory `value` was made in.
pub fn copy(comptime Value: type, arena: std.mem.Allocator, value: Value) error{OutOfMemory}!Value {
    comptime std.debug.assert(plain(Value));

    switch (@typeInfo(Value)) {
        .bool, .int, .float, .@"enum", .void => return value,
        .optional => |info| {
            const held = value orelse return null;

            return try copy(info.child, arena, held);
        },
        .array => |info| {
            var copied: Value = undefined;

            for (value, &copied) |item, *target| {
                target.* = try copy(info.child, arena, item);
            }

            return copied;
        },
        .pointer => |info| return copy_list(info.child, arena, value),
        .@"struct" => |info| {
            if (info.layout == .@"packed") {
                return value;
            }

            var copied: Value = undefined;

            inline for (info.field_names, info.field_types) |name, Field| {
                @field(copied, name) = try copy(Field, arena, @field(value, name));
            }

            return copied;
        },
        .@"union" => |info| {
            inline for (info.field_names, info.field_types) |name, Field| {
                if (value == @field(std.meta.Tag(Value), name)) {
                    return @unionInit(Value, name, try copy(Field, arena, @field(value, name)));
                }
            }

            unreachable;
        },
        else => comptime unreachable,
    }
}

fn copy_list(
    comptime Item: type,
    arena: std.mem.Allocator,
    value: []const Item,
) error{OutOfMemory}![]Item {
    const copied = try arena.alloc(Item, value.len);

    std.debug.assert(copied.len == value.len);

    // Texts and lists of values holding no list of their own are one copy.
    if (comptime flat(Item)) {
        @memcpy(copied, value);

        return copied;
    }

    for (value, copied) |item, *target| {
        target.* = try copy(Item, arena, item);
    }

    return copied;
}

/// Whether a value of `Item` holds no text or list: its bytes are the whole of it.
fn flat(comptime Item: type) bool {
    return switch (@typeInfo(Item)) {
        .bool, .int, .float, .@"enum", .void => true,
        else => false,
    };
}

test "an answer is copied whole: nothing of the copy lies where it was made" {
    const Line = struct {
        title: []const u8,
        amounts: []const i64,
        note: ?[]const u8 = null,
    };
    const Choice = union(enum) {
        none: void,
        named: []const u8,
    };
    const Answer = struct {
        lines: []const Line,
        choice: Choice,
        total: i64,
        pair: [2][]const u8,
    };
    var buffer: [512]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const working = fixed.allocator();
    const lines = try working.alloc(Line, 2);

    lines[0] = .{
        .title = try working.dupe(u8, "Tea"),
        .amounts = try working.dupe(i64, &.{ 1, 2, 3 }),
        .note = try working.dupe(u8, "kept"),
    };
    lines[1] = .{
        .title = try working.dupe(u8, "Cup"),
        .amounts = &.{},
    };

    const made: Answer = .{
        .lines = lines,
        .choice = .{
            .named = try working.dupe(u8, "courier"),
        },
        .total = 6,
        .pair = .{ try working.dupe(u8, "left"), try working.dupe(u8, "right") },
    };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const copied = try copy(Answer, arena_state.allocator(), made);

    // The working memory given back and written over: the copy still reads.
    @memset(&buffer, 0xaa);

    try std.testing.expectEqual(@as(usize, 2), copied.lines.len);
    try std.testing.expectEqualStrings("Tea", copied.lines[0].title);
    try std.testing.expectEqualSlices(i64, &.{ 1, 2, 3 }, copied.lines[0].amounts);
    try std.testing.expectEqualStrings("kept", copied.lines[0].note.?);
    try std.testing.expect(copied.lines[1].note == null);
    try std.testing.expectEqualStrings("courier", copied.choice.named);
    try std.testing.expectEqualStrings("right", copied.pair[1]);
    try std.testing.expectEqual(@as(i64, 6), copied.total);
}

test "an answer that points at something else is not plain, and out of memory is said" {
    const Open = struct {
        rows: *u32,
    };
    const Called = struct {
        run: *const fn () void,
    };
    const Text = struct {
        text: []const u8,
    };
    var none: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&none);

    const Node = struct {
        name: []const u8,
        children: []const @This(),
    };

    try std.testing.expect(!plain(Node));
    try std.testing.expect(!plain(Open));
    try std.testing.expect(!plain(Called));
    try std.testing.expect(!plain([*:0]const u8));
    try std.testing.expect(plain(Text));
    try std.testing.expect(plain(?[]const Text));
    try std.testing.expect(settled(?[]const Text));
    try std.testing.expect(plain([]Text) and !settled([]Text));
    try std.testing.expect(!settled(Open));
    try std.testing.expectError(error.OutOfMemory, copy(Text, fixed.allocator(), .{
        .text = "more than nothing",
    }));
}
