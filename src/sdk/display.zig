//! Display hooks: a plugin changes how a value is shown, never what is stored. Core hands a
//! hook a batch (each item's value as it would be shown and every field of its record) and
//! the hook changes the values in place; it reads anything else through the SDK, as
//! granted. What comes back is text: cut to `value_bytes_max`, control characters made
//! spaces, and escaped wherever it is shown. A hook that fails, or hands back another
//! batch, leaves the values as they were.

const std = @import("std");

/// Where a value can be changed: a record's title, wherever the admin shows one.
pub const points = [_][]const u8{"record.title"};

pub const value_bytes_max: u32 = 512;
pub const batch_items_max: u32 = 200;

pub const Item = struct {
    id: []const u8,
    /// What is shown now; the hook writes what is shown instead.
    value: []const u8,
    /// Every field of the record, as stored.
    fields: std.json.Value = .null,
};

pub const Batch = struct { items: []Item };

pub fn validate(comptime Middleware: type) void {
    comptime {
        const type_name = @typeName(Middleware);

        if (!@hasDecl(Middleware, "point") or !@hasDecl(Middleware, "content_type")) {
            @compileError(type_name ++ ": a display hook names its `point` and `content_type`");
        }

        for (points) |point| {
            if (std.mem.eql(u8, point, Middleware.point)) {
                break;
            }
        } else @compileError(type_name ++ ": no display point " ++ Middleware.point);

        if (Middleware.content_type.len == 0) {
            @compileError(type_name ++ ": empty `content_type`");
        }
    }
}

/// `record.title/variant`: what a display hook is on, as the sandbox indexes and grants it.
pub fn target_of(comptime Middleware: type) []const u8 {
    comptime {
        std.debug.assert(Middleware.point.len > 0);

        return Middleware.point ++ "/" ++ Middleware.content_type;
    }
}

pub fn target_text(
    buffer: []u8,
    point: []const u8,
    content_type: []const u8,
) error{NoSpaceLeft}![]const u8 {
    std.debug.assert(point.len > 0);
    std.debug.assert(content_type.len > 0);

    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ point, content_type });
}

/// The values as shown: each hook's answer cut and cleaned, or the original value when the
/// answer is not a value at all.
pub fn settle(arena: std.mem.Allocator, batch: *Batch) error{OutOfMemory}!void {
    std.debug.assert(batch.items.len <= batch_items_max);

    for (batch.items) |*item| {
        item.value = try cleaned(arena, item.value);
    }
}

/// Takes the values of `changed` into `batch`, by position, when it is the same batch: the
/// same ids in the same order. Anything else is ignored.
pub fn take(batch: *Batch, changed: Batch) bool {
    std.debug.assert(batch.items.len <= batch_items_max);

    if (changed.items.len != batch.items.len) {
        return false;
    }

    for (batch.items, changed.items) |kept, item| {
        if (!std.mem.eql(u8, kept.id, item.id)) {
            return false;
        }
    }

    for (batch.items, changed.items) |*kept, item| {
        kept.value = item.value;
    }

    return true;
}

fn cleaned(arena: std.mem.Allocator, value: []const u8) error{OutOfMemory}![]const u8 {
    std.debug.assert(value_bytes_max > 0);

    var end: u32 = @intCast(@min(value.len, value_bytes_max));

    while (end > 0 and end < value.len and (value[end] & 0xC0) == 0x80) {
        end -= 1;
    }

    const kept = value[0..end];

    if (!std.unicode.utf8ValidateSlice(kept)) {
        return "";
    }

    const out = try arena.dupe(u8, kept);

    for (out) |*char| {
        if (char.* < 0x20 or char.* == 0x7f) {
            char.* = ' ';
        }
    }

    return out;
}

test "a hook's answer is text: cut on a character, control characters made spaces" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var items = [_]Item{
        .{ .id = "a", .value = "Earl Grey,\n50 g" },
        .{ .id = "b", .value = "é" ** 400 },
        .{ .id = "c", .value = "\xff\xfe" },
    };
    var batch: Batch = .{ .items = &items };

    try settle(arena, &batch);
    try std.testing.expectEqualStrings("Earl Grey, 50 g", items[0].value);
    try std.testing.expectEqual(@as(usize, value_bytes_max), items[1].value.len);
    try std.testing.expectEqualStrings("", items[2].value);

    var swapped = [_]Item{ .{ .id = "b", .value = "x" }, .{ .id = "a", .value = "y" } };
    var two = [_]Item{ .{ .id = "a", .value = "1" }, .{ .id = "b", .value = "2" } };
    var kept: Batch = .{ .items = &two };

    try std.testing.expect(!take(&kept, .{ .items = &swapped }));
    try std.testing.expectEqualStrings("1", two[0].value);

    var same = [_]Item{ .{ .id = "a", .value = "A" }, .{ .id = "b", .value = "B" } };

    try std.testing.expect(take(&kept, .{ .items = &same }));
    try std.testing.expectEqualStrings("B", two[1].value);
}
