//! A value whose shape comes with the data (a record's document, a query's result), in bytes
//! that are read where they lie: no text is written or parsed to hand one over. A plugin and
//! Publr pass it across the sandbox's boundary as it is; Publr turns it into JSON only where
//! it keeps or sends JSON.
//!
//! One value, byte by byte (numbers little-endian):
//! `0` null · `1` false · `2` true · `3` int:i64 · `4` float:f64 · `5` len:u32 text ·
//! `6` size:u32 count:u32 items · `7` size:u32 count:u32, then key_len:u32 key value each.
//! `size` is how many bytes the items or entries take together, so a part is stepped over
//! without being walked.
const std = @import("std");

/// How deep lists and maps may nest.
pub const depth_max: u32 = 64;

pub const Kind = enum(u8) {
    null = 0,
    false = 1,
    true = 2,
    int = 3,
    float = 4,
    text = 5,
    list = 6,
    map = 7,
};

const kinds_count: u8 = 8;

/// A value read where it lies. Every getter answers null for bytes that are cut short or
/// say another kind, so a value that is not well made reads as nothing, never past its end.
pub const Value = struct {
    bytes: []const u8 = &.{@backingInt(Kind.null)},

    pub const Entry = struct {
        key: []const u8,
        value: Value,
    };

    pub fn kind(value: Value) Kind {
        if (value.bytes.len == 0 or value.bytes[0] >= kinds_count) {
            return .null;
        }

        std.debug.assert(value.bytes[0] < kinds_count);

        return @fromBackingInt(@intCast(value.bytes[0]));
    }

    pub fn is_null(value: Value) bool {
        return value.kind() == .null;
    }

    pub fn boolean(value: Value) ?bool {
        std.debug.assert(value.bytes.len == 0 or value.bytes.len >= 1);

        return switch (value.kind()) {
            .true => true,
            .false => false,
            else => null,
        };
    }

    pub fn int(value: Value) ?i64 {
        if (value.kind() != .int or value.bytes.len < 9) {
            return null;
        }

        return std.mem.readInt(i64, value.bytes[1..9], .little);
    }

    /// A float, or an int as one.
    pub fn float(value: Value) ?f64 {
        if (value.int()) |whole| {
            return @floatFromInt(whole);
        }

        if (value.kind() != .float or value.bytes.len < 9) {
            return null;
        }

        std.debug.assert(value.bytes[0] == @backingInt(Kind.float));

        return @bitCast(std.mem.readInt(u64, value.bytes[1..9], .little));
    }

    pub fn text(value: Value) ?[]const u8 {
        if (value.kind() != .text or value.bytes.len < 5) {
            return null;
        }

        const len = std.mem.readInt(u32, value.bytes[1..5], .little);

        if (len > value.bytes.len - 5) {
            return null;
        }

        std.debug.assert(@as(u64, len) + 5 <= value.bytes.len);

        return value.bytes[5..][0..len];
    }

    /// How many items a list holds, or entries a map; 0 for anything else.
    pub fn count(value: Value) u32 {
        const held = value.kind();

        if ((held != .list and held != .map) or value.bytes.len < 9) {
            return 0;
        }

        std.debug.assert(value.bytes[0] >= @backingInt(Kind.list));

        return std.mem.readInt(u32, value.bytes[5..9], .little);
    }

    /// The bytes of a list's items or a map's entries.
    fn body(value: Value, wanted: Kind) []const u8 {
        std.debug.assert(wanted == .list or wanted == .map);

        if (value.kind() != wanted or value.bytes.len < 9) {
            return &.{};
        }

        const size = std.mem.readInt(u32, value.bytes[1..5], .little);

        if (size > value.bytes.len - 9) {
            return &.{};
        }

        return value.bytes[9..][0..size];
    }

    pub fn items(value: Value) Items {
        return .{
            .left = value.body(.list),
        };
    }

    pub fn entries(value: Value) Entries {
        return .{
            .left = value.body(.map),
        };
    }

    /// A list's item `index`.
    pub fn at(value: Value, index: u32) ?Value {
        var walk = value.items();
        var passed: u32 = 0;

        while (walk.next()) |item| : (passed += 1) {
            if (passed == index) {
                return item;
            }
        }

        std.debug.assert(passed <= index);

        return null;
    }

    /// A map's value under `key`.
    pub fn get(value: Value, key: []const u8) ?Value {
        var walk = value.entries();

        while (walk.next()) |entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                return entry.value;
            }
        }

        std.debug.assert(walk.left.len <= value.bytes.len);

        return null;
    }
};

pub const Items = struct {
    left: []const u8,

    pub fn next(walk: *Items) ?Value {
        const len = span(walk.left) orelse return null;
        const item: Value = .{
            .bytes = walk.left[0..len],
        };

        std.debug.assert(len > 0);
        walk.left = walk.left[len..];

        return item;
    }
};

pub const Entries = struct {
    left: []const u8,

    pub fn next(walk: *Entries) ?Value.Entry {
        if (walk.left.len < 4) {
            return null;
        }

        const key_len = std.mem.readInt(u32, walk.left[0..4], .little);

        if (key_len > walk.left.len - 4) {
            return null;
        }

        const after = walk.left[4 + key_len ..];
        const len = span(after) orelse return null;
        const entry: Value.Entry = .{
            .key = walk.left[4..][0..key_len],
            .value = .{
                .bytes = after[0..len],
            },
        };

        std.debug.assert(len > 0);
        walk.left = after[len..];

        return entry;
    }
};

/// How many bytes the value at the start of `bytes` takes; null when it is cut short or of
/// no kind.
pub fn span(bytes: []const u8) ?u32 {
    if (bytes.len == 0 or bytes[0] >= kinds_count) {
        return null;
    }

    const held: Kind = @fromBackingInt(@intCast(bytes[0]));
    const needed: u64 = switch (held) {
        .null, .false, .true => 1,
        .int, .float => 9,
        .text => if (bytes.len < 5) return null else 5 + @as(u64, std.mem.readInt(
            u32,
            bytes[1..5],
            .little,
        )),
        .list, .map => if (bytes.len < 9) return null else 9 + @as(u64, std.mem.readInt(
            u32,
            bytes[1..5],
            .little,
        )),
    };

    if (needed > bytes.len) {
        return null;
    }

    std.debug.assert(needed <= std.math.maxInt(u32) + 9);

    return @intCast(needed);
}

/// Whether the value at the start of `bytes` takes all of them.
pub fn complete(bytes: []const u8) bool {
    const len = span(bytes) orelse return false;

    std.debug.assert(len <= bytes.len);

    return len == bytes.len;
}

/// Whether `bytes` is exactly one well-made value: every length inside its part, every count
/// the number of items there, every text and key UTF-8, nested no deeper than `depth_max`.
pub fn valid(bytes: []const u8) bool {
    std.debug.assert(bytes.len <= std.math.maxInt(u32) or !complete(bytes));

    return complete(bytes) and valid_inside(bytes, 0);
}

fn valid_inside(bytes: []const u8, depth: u32) bool {
    const value: Value = .{
        .bytes = bytes,
    };

    std.debug.assert(complete(bytes));

    switch (value.kind()) {
        .null, .false, .true, .int, .float => return true,
        .text => return std.unicode.utf8ValidateSlice(bytes[5..]),
        .list, .map => {},
    }

    if (depth >= depth_max) {
        return false;
    }

    var left: []const u8 = bytes[9..];
    var seen: u32 = 0;

    while (left.len > 0) : (seen += 1) {
        if (value.kind() == .map) {
            if (left.len < 4) {
                return false;
            }

            const key_len = std.mem.readInt(u32, left[0..4], .little);

            if (key_len > left.len - 4 or !std.unicode.utf8ValidateSlice(left[4..][0..key_len])) {
                return false;
            }

            left = left[4 + key_len ..];
        }

        const len = span(left) orelse return false;

        if (!valid_inside(left[0..len], depth + 1)) {
            return false;
        }

        left = left[len..];
    }

    return seen == value.count();
}

test "a value reads where it lies; one cut short or lying about itself reads as nothing" {
    const builder_module = @import("free_builder.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var builder: builder_module.Builder = .init(arena_state.allocator());

    try builder.begin_map();
    try builder.key("PLN");
    try builder.int(12300);
    try builder.key("tags");
    try builder.begin_list();
    try builder.text("tea");
    try builder.boolean(true);
    try builder.float(1.5);
    try builder.nothing();
    try builder.end();
    try builder.end();

    const value = try builder.done();

    try std.testing.expect(valid(value.bytes));
    try std.testing.expectEqual(@as(u32, 2), value.count());
    try std.testing.expectEqual(@as(?i64, 12300), value.get("PLN").?.int());
    try std.testing.expect(value.get("EUR") == null);

    const tags = value.get("tags").?;

    try std.testing.expectEqual(@as(u32, 4), tags.count());
    try std.testing.expectEqualStrings("tea", tags.at(0).?.text().?);
    try std.testing.expectEqual(@as(?bool, true), tags.at(1).?.boolean());
    try std.testing.expectEqual(@as(?f64, 1.5), tags.at(2).?.float());
    try std.testing.expect(tags.at(3).?.is_null() and tags.at(4) == null);

    // Cut anywhere, it is no value, and no getter reads past what is left.
    for (0..value.bytes.len) |len| {
        const cut: Value = .{
            .bytes = value.bytes[0..len],
        };

        try std.testing.expect(!valid(cut.bytes));
        _ = cut.get("tags");
        _ = cut.at(3);
        _ = cut.text();
    }
}

test "a count, a length, a text or a nesting that lies is refused" {
    const good = [_]u8{ 6, 2, 0, 0, 0, 2, 0, 0, 0, 1, 2 };
    var count = good;
    var size = good;
    var kind = good;
    const text = [_]u8{ 5, 2, 0, 0, 0, 0xff, 0xfe };
    const key = [_]u8{ 7, 6, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0xff, 0 };

    count[5] = 3;
    size[1] = 0xff;
    kind[9] = 9;

    try std.testing.expect(valid(&good));
    try std.testing.expect(!valid(&count) and !valid(&size) and !valid(&kind));
    try std.testing.expect(!valid(&text) and !valid(&key) and !valid(&.{}));
    try std.testing.expect(!valid(&(good ++ [_]u8{0})));

    // A list in a list, deeper than a value may nest.
    var deep: [(depth_max + 2) * 9 + 1]u8 = undefined;

    for (0..depth_max + 2) |level| {
        const inside: u32 = @intCast(deep.len - (level + 1) * 9);

        deep[level * 9] = 6;
        std.mem.writeInt(u32, deep[level * 9 + 1 ..][0..4], inside, .little);
        std.mem.writeInt(u32, deep[level * 9 + 5 ..][0..4], 1, .little);
    }

    deep[deep.len - 1] = 0;
    try std.testing.expect(!valid(&deep));
    try std.testing.expect(valid(deep[2 * 9 ..]));
}
