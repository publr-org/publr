//! Time zones by name (`Europe/Warsaw`), each with its current rule as a POSIX TZ string
//! (`CET-1CEST,M3.5.0,M10.5.0/3`), from `zone/zones.txt` (`scripts/zones.sh` writes it). What
//! a site's clock reads at a moment: the zone's offset, summer time included. Only the rule
//! in force now; past changes of a zone's rules are not kept, as only times to come are asked.
const std = @import("std");

const zones_text = @embedFile("zone/zones.txt");

pub const name_len_max: u32 = 64;

const second_ms: i64 = 1000;
const hour_s: i64 = 60 * 60;
const day_ms: i64 = 24 * hour_s * second_ms;

/// Every zone's name, `UTC` first, then the rest in order.
pub fn names(arena: std.mem.Allocator) error{OutOfMemory}![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, zones_text, '\n');

    while (lines.next()) |line| {
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;

        try list.append(arena, line[0..space]);
    }

    std.debug.assert(list.items.len > 0);

    return list.items;
}

/// The rule of the zone named `name`; null for a name no zone has.
pub fn rule_of(name: []const u8) ?[]const u8 {
    std.debug.assert(zones_text.len > 0);

    if (name.len == 0 or name.len > name_len_max) {
        return null;
    }

    var lines = std.mem.tokenizeScalar(u8, zones_text, '\n');

    while (lines.next()) |line| {
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;

        if (std.mem.eql(u8, line[0..space], name)) {
            return line[space + 1 ..];
        }
    }

    return null;
}

/// How far the zone's clock is ahead of UTC at `utc_ms`, in ms: what to add to a UTC moment
/// to read it on that clock. A rule that does not read counts as UTC.
pub fn offset_ms(rule: []const u8, utc_ms: i64) i64 {
    std.debug.assert(rule.len <= 128);

    const parsed = parse(rule) orelse return 0;
    const summer = parsed.summer orelse return parsed.standard_ms;
    const local_year = year_of(utc_ms + parsed.standard_ms);
    const starts = summer.start.utc_ms(local_year, parsed.standard_ms);
    const ends = summer.end.utc_ms(local_year, summer.offset_ms);
    const in_summer = if (starts < ends)
        utc_ms >= starts and utc_ms < ends
    else
        !(utc_ms >= ends and utc_ms < starts);

    return if (in_summer) summer.offset_ms else parsed.standard_ms;
}

/// The UTC moment a clock of the zone shows `local_ms` (ms since 1970 read as UTC). A time
/// summer time skips reads an hour later; one it repeats, the second.
pub fn utc_of(rule: []const u8, local_ms: i64) i64 {
    std.debug.assert(rule.len <= 128);

    const guess = local_ms - offset_ms(rule, local_ms);
    const settled = local_ms - offset_ms(rule, guess);

    return @max(guess, settled);
}

const Rule = struct {
    standard_ms: i64,
    summer: ?Summer = null,
};

const Summer = struct {
    offset_ms: i64,
    start: Change,
    end: Change,
};

/// `Mm.w.d/time`: day `d` (0 Sunday) of week `w` (5 the last) of month `m`, at `time` on the
/// clock in force before it.
const Change = struct {
    month: u8,
    week: u8,
    day: u8,
    time_s: i64 = 2 * hour_s,

    fn utc_ms(change: Change, year: i64, before_ms: i64) i64 {
        std.debug.assert(change.month >= 1 and change.month <= 12);
        std.debug.assert(change.week >= 1 and change.week <= 5);

        const first = days_from_civil(year, change.month, 1);
        const weekday = @mod(first + 4, 7);
        var day = first + @mod(@as(i64, change.day) - weekday, 7) + (change.week - 1) * 7;
        const next_month = if (change.month == 12)
            days_from_civil(year + 1, 1, 1)
        else
            days_from_civil(year, change.month + 1, 1);

        while (day >= next_month) {
            day -= 7;
        }

        return day * day_ms + change.time_s * second_ms - before_ms;
    }
};

const Reader = struct {
    text: []const u8,
    at: usize = 0,

    fn peek(reader: *const Reader) u8 {
        return if (reader.at < reader.text.len) reader.text[reader.at] else 0;
    }

    fn take(reader: *Reader, char: u8) bool {
        std.debug.assert(reader.at <= reader.text.len);

        if (reader.peek() != char) {
            return false;
        }

        reader.at += 1;

        return true;
    }

    /// A zone's abbreviation: letters, or anything within `<` and `>`.
    fn name(reader: *Reader) ?void {
        std.debug.assert(reader.at <= reader.text.len);

        if (reader.take('<')) {
            const close = std.mem.indexOfScalarPos(u8, reader.text, reader.at, '>') orelse
                return null;

            reader.at = close + 1;

            return;
        }

        const start = reader.at;

        while (std.ascii.isAlphabetic(reader.peek())) {
            reader.at += 1;
        }

        if (reader.at - start < 3) {
            return null;
        }
    }

    fn number(reader: *Reader) ?i64 {
        std.debug.assert(reader.at <= reader.text.len);

        const start = reader.at;

        while (std.ascii.isDigit(reader.peek())) {
            reader.at += 1;
        }

        return std.fmt.parseInt(i64, reader.text[start..reader.at], 10) catch null;
    }

    /// `[+-]h[:m[:s]]` in seconds.
    fn time(reader: *Reader) ?i64 {
        std.debug.assert(reader.at <= reader.text.len);

        const negative = reader.take('-');

        if (!negative) {
            _ = reader.take('+');
        }

        var seconds = (reader.number() orelse return null) * hour_s;

        if (reader.take(':')) {
            seconds += (reader.number() orelse return null) * 60;

            if (reader.take(':')) {
                seconds += reader.number() orelse return null;
            }
        }

        return if (negative) -seconds else seconds;
    }

    fn change(reader: *Reader) ?Change {
        std.debug.assert(reader.at <= reader.text.len);

        if (!reader.take('M')) {
            return null;
        }

        const month = reader.number() orelse return null;

        if (!reader.take('.')) {
            return null;
        }

        const week = reader.number() orelse return null;

        if (!reader.take('.')) {
            return null;
        }

        const day = reader.number() orelse return null;

        if (month < 1 or month > 12 or week < 1 or week > 5 or day > 6) {
            return null;
        }

        var made: Change = .{
            .month = @intCast(month),
            .week = @intCast(week),
            .day = @intCast(day),
        };

        if (reader.take('/')) {
            made.time_s = reader.time() orelse return null;
        }

        return made;
    }
};

/// A POSIX TZ string read; null when it does not read. Its offsets count west, so their sign
/// is turned.
fn parse(text: []const u8) ?Rule {
    std.debug.assert(text.len <= 128);

    var reader: Reader = .{
        .text = text,
    };

    reader.name() orelse return null;

    const standard_ms = -(reader.time() orelse return null) * second_ms;

    if (reader.at == text.len) {
        return .{
            .standard_ms = standard_ms,
        };
    }

    reader.name() orelse return null;

    const peeked = reader.peek();
    const summer_ms = if (peeked != ',')
        -(reader.time() orelse return null) * second_ms
    else
        standard_ms + hour_s * second_ms;

    if (!reader.take(',')) {
        return null;
    }

    const start = reader.change() orelse return null;

    if (!reader.take(',')) {
        return null;
    }

    const end = reader.change() orelse return null;

    return .{
        .standard_ms = standard_ms,
        .summer = .{
            .offset_ms = summer_ms,
            .start = start,
            .end = end,
        },
    };
}

/// Days since 1970-01-01 of a date of the Gregorian calendar.
fn days_from_civil(year: i64, month: u8, day: u8) i64 {
    std.debug.assert(month >= 1 and month <= 12);
    std.debug.assert(day >= 1 and day <= 31);

    const counted = if (month <= 2) year - 1 else year;
    const era = @divFloor(counted, 400);
    const year_of_era = counted - era * 400;
    const shifted: i64 = if (month > 2) month - 3 else month + 9;
    const day_of_year = @divFloor(153 * shifted + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;

    return era * 146097 + day_of_era - 719468;
}

/// The year a moment (ms since 1970, read as UTC) falls in.
fn year_of(ms: i64) i64 {
    std.debug.assert(ms > -(1 << 50) and ms < 1 << 50);

    const days = @divFloor(ms, day_ms) + 719468;
    const era = @divFloor(days, 146097);
    const day_of_era = days - era * 146097;
    const year_of_era = @divFloor(day_of_era - @divFloor(day_of_era, 1460) +
        @divFloor(day_of_era, 36524) - @divFloor(day_of_era, 146096), 365);
    const day_of_year = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100));
    const month_index = @divFloor(5 * day_of_year + 2, 153);

    return year_of_era + era * 400 + @as(i64, if (month_index >= 10) 1 else 0);
}

test "Warsaw's clock: an hour ahead in winter, two in summer, changing on the last Sundays" {
    const warsaw = rule_of("Europe/Warsaw").?;
    const hour_ms = hour_s * second_ms;

    // 2026-01-15 12:00 UTC, 2026-07-15 12:00 UTC.
    try std.testing.expectEqual(hour_ms, offset_ms(warsaw, 1_768_478_400_000));
    try std.testing.expectEqual(2 * hour_ms, offset_ms(warsaw, 1_784_116_800_000));
    // Summer time starts 2026-03-29 01:00 UTC and ends 2026-10-25 01:00 UTC.
    try std.testing.expectEqual(hour_ms, offset_ms(warsaw, 1_774_746_000_000 - 1));
    try std.testing.expectEqual(2 * hour_ms, offset_ms(warsaw, 1_774_746_000_000));
    try std.testing.expectEqual(2 * hour_ms, offset_ms(warsaw, 1_792_890_000_000 - 1));
    try std.testing.expectEqual(hour_ms, offset_ms(warsaw, 1_792_890_000_000));
    // 03:00 on Warsaw's clock on 2026-07-15 is 01:00 UTC.
    try std.testing.expectEqual(1_784_077_200_000, utc_of(warsaw, 1_784_084_400_000));

    // Sydney's summer spans the new year; Kolkata has none, and half an hour.
    const sydney = rule_of("Australia/Sydney").?;

    try std.testing.expectEqual(11 * hour_ms, offset_ms(sydney, 1_768_478_400_000));
    try std.testing.expectEqual(10 * hour_ms, offset_ms(sydney, 1_784_116_800_000));
    try std.testing.expectEqual(11 * hour_ms / 2, offset_ms(rule_of("Asia/Kolkata").?, 0));
    try std.testing.expectEqual(0, offset_ms(rule_of("UTC").?, 0));
    try std.testing.expectEqual(null, rule_of("Mars/Olympus"));

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectEqualStrings("UTC", (try names(arena_state.allocator()))[0]);
}
