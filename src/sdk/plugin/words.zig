//! What a plugin's code says, the same whichever way it runs: text for people with named
//! values (`"Only {left} left"`), refusals whose status comes from the operation's `Fails:`,
//! log lines with a level, and the call's time as `publr.Time`.
const std = @import("std");
const operation = @import("../operation.zig");

pub const Level = enum { info, warn, err };

pub const message_len_max: u32 = operation.failure_message_len_max;

/// A moment, as a `datetime` field holds it: milliseconds since 1970, UTC.
pub const Time = struct {
    ms: i64,

    pub fn before(time: Time, other: Time) bool {
        std.debug.assert(time.ms >= 0);
        std.debug.assert(other.ms >= 0);

        return time.ms < other.ms;
    }

    pub fn add_minutes(time: Time, minutes: i64) Time {
        std.debug.assert(time.ms >= 0);
        std.debug.assert(minutes > -(1 << 40) and minutes < (1 << 40));

        return .{
            .ms = time.ms + minutes * std.time.ms_per_min,
        };
    }

    pub fn add_days(time: Time, days: i64) Time {
        std.debug.assert(time.ms >= 0);
        std.debug.assert(days > -(1 << 30) and days < (1 << 30));

        return .{
            .ms = time.ms + days * std.time.ms_per_day,
        };
    }

    pub fn jsonStringify(time: Time, writer: anytype) !void {
        std.debug.assert(time.ms >= 0);

        try writer.write(time.ms);
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !Time {
        const ms = try std.json.innerParse(i64, allocator, source, options);

        return .{
            .ms = ms,
        };
    }
};

/// `text` with each `{name}` the value of `values`' field of that name.
pub fn filled(arena: std.mem.Allocator, comptime text: []const u8, values: anytype) ![]const u8 {
    comptime std.debug.assert(text.len > 0);

    var out: []const u8 = text;

    inline for (std.meta.fields(@TypeOf(values))) |field| {
        const hole = "{" ++ field.name ++ "}";
        const value = try shown(arena, @field(values, field.name));

        out = try std.mem.replaceOwned(u8, arena, out, hole, value);
    }

    std.debug.assert(out.len < 1 << 24);

    return out;
}

/// One value as text: text as it is, numbers and the rest as Zig prints them.
pub fn shown(arena: std.mem.Allocator, value: anytype) ![]const u8 {
    const Value = @TypeOf(value);

    comptime std.debug.assert(@sizeOf(Value) <= 1 << 16);

    if (comptime is_text(Value)) {
        return value;
    }

    return std.fmt.allocPrint(arena, "{any}", .{value});
}

fn is_text(comptime Value: type) bool {
    comptime {
        std.debug.assert(@typeInfo(Value) != .void);

        const info = @typeInfo(Value);

        if (info != .pointer) {
            return false;
        }

        const pointer = info.pointer;

        if (pointer.size == .slice) {
            return pointer.child == u8;
        }

        return pointer.size == .one and @typeInfo(pointer.child) == .array and
            @typeInfo(pointer.child).array.child == u8;
    }
}

/// An operation's declared failures as a slice, whichever way it lists them.
pub fn failures_of(comptime Operation: type) []const operation.Failure {
    comptime {
        std.debug.assert(Operation.name.len > 0);

        if (!@hasDecl(Operation, "failures")) {
            return &.{};
        }

        const list = Operation.failures;

        if (@typeInfo(@TypeOf(list)) == .array) {
            return &list;
        }

        return list;
    }
}

/// The status an operation's `Fails:` gives `name`; 409 when it gives none.
pub fn status_of(failures: []const operation.Failure, name: []const u8) u16 {
    std.debug.assert(name.len > 0);
    std.debug.assert(failures.len <= 64);

    for (failures) |failure| {
        if (std.mem.eql(u8, failure.name, name)) {
            return failure.status;
        }
    }

    // `.validate`'s problems: the input does not hold.
    if (std.mem.eql(u8, name, "Invalid")) {
        return 422;
    }

    return 409;
}

/// The message cut to what a failure may carry.
pub fn kept(message: []const u8) []const u8 {
    std.debug.assert(message_len_max > 0);

    const cut = message[0..@min(message.len, message_len_max)];

    std.debug.assert(cut.len <= message_len_max);

    return cut;
}

test "named values filled, statuses found" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = try filled(arena, "Only {left} of {name} left", .{
        .left = @as(u32, 2),
        .name = "tea",
    });

    try std.testing.expectEqualStrings("Only 2 of tea left", text);

    const failures = [_]operation.Failure{.{
        .name = "OfferEnded",
        .status = 410,
        .message = "the offer ended",
    }};

    try std.testing.expectEqual(410, status_of(&failures, "OfferEnded"));
    try std.testing.expectEqual(409, status_of(&failures, "NotEnoughStock"));

    const now: Time = .{
        .ms = 1000,
    };

    try std.testing.expect(now.before(now.add_minutes(1)));
    try std.testing.expect(now.before(now.add_days(1)));
}
