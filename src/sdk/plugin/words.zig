//! What a plugin's code says, the same whichever way it runs: text for people with named
//! values (`"Only {left} left"`), refusals whose status comes from the operation's `Fails:`,
//! log lines with a level, and the call's time as `publr.Time`.
const std = @import("std");
const operation = @import("../operation.zig");

pub const Level = enum { info, warn, err };

pub const message_len_max: u32 = operation.failure_message_len_max;

/// A moment, as a `datetime` field holds it: milliseconds since 1970, UTC.
const calendar = @import("../../model/calendar.zig");

/// A day on the calendar: `time.local_date(zone)`, `date.add_months(1)`,
/// `check_in.days_until(check_out)`.
pub const Date = calendar.Date;

/// The site's time zone, as `ctx.time_zone()` answers it: its name (`Europe/Warsaw`) and its
/// rule, summer time included.
pub const TimeZone = struct {
    name: []const u8 = "UTC",
    /// The POSIX rule (`CET-1CEST,M3.5.0,M10.5.0/3`).
    rule: []const u8 = "UTC0",
};

pub const Time = struct {
    ms: i64,

    /// Written as its milliseconds, in JSON and in an operation's shape.
    pub const json_scalar: @import("../../model/contract.zig").Kind = .integer;
    pub const json_label = "milliseconds since 1970";
    /// Handed over as its milliseconds.
    pub const publr_form = .inner;

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

    /// The date it falls on, on the zone's clock (`ctx.time_zone()`).
    pub fn local_date(time: Time, zone: TimeZone) Date {
        std.debug.assert(time.ms >= 0);
        std.debug.assert(zone.rule.len > 0);

        return calendar.local_date(zone.rule, time.ms);
    }

    /// The moment its day starts on the zone's clock.
    pub fn start_of_day(time: Time, zone: TimeZone) Time {
        std.debug.assert(time.ms >= 0);
        std.debug.assert(zone.rule.len > 0);

        return .{
            .ms = calendar.start_of(zone.rule, time.local_date(zone)),
        };
    }

    /// The moment its day ends on the zone's clock: the next day's start, not in it.
    pub fn end_of_day(time: Time, zone: TimeZone) Time {
        std.debug.assert(time.ms >= 0);
        std.debug.assert(zone.rule.len > 0);

        return .{
            .ms = calendar.start_of(zone.rule, time.local_date(zone).add_days(1)),
        };
    }

    /// `months` later on the zone's clock: the same time of day, the same day of the month
    /// or the month's last (31 January and a month is the end of February). Never 30 days.
    pub fn add_months(time: Time, zone: TimeZone, months: i64) Time {
        std.debug.assert(time.ms >= 0);
        std.debug.assert(zone.rule.len > 0);

        return .{
            .ms = calendar.add_months(zone.rule, time.ms, months),
        };
    }

    pub fn add_years(time: Time, zone: TimeZone, years: i64) Time {
        std.debug.assert(time.ms >= 0);
        std.debug.assert(years > -(1 << 16) and years < (1 << 16));

        return time.add_months(zone, years * 12);
    }

    /// Whole days from its date to `other`'s on the zone's clock: nights between a check-in
    /// and a check-out.
    pub fn days_until(time: Time, zone: TimeZone, other: Time) i64 {
        std.debug.assert(time.ms >= 0);
        std.debug.assert(other.ms >= 0);

        return time.local_date(zone).days_until(other.local_date(zone));
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

    inline for (comptime std.meta.fieldNames(@TypeOf(values))) |field_name| {
        const hole = "{" ++ field_name ++ "}";
        const value = try shown(arena, @field(values, field_name));

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
