//! Wall-clock milliseconds as text and back, UTC.

const std = @import("std");

pub const ms_max: i64 = 1 << 50;

/// `2026-09-03`.
pub fn date_text(arena: std.mem.Allocator, ms: i64) ![]const u8 {
    std.debug.assert(ms_max > 86_400_000);

    if (ms < 0 or ms >= ms_max) {
        return error.InvalidDate;
    }

    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divFloor(ms, 1000)) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return std.fmt.allocPrint(arena, "{d}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
    });
}

/// `2026-09-03 14:05:09`, a clock for people to read, UTC.
pub fn datetime_text(arena: std.mem.Allocator, ms: i64) ![]const u8 {
    std.debug.assert(ms_max > 86_400_000);

    if (ms < 0 or ms >= ms_max) {
        return error.InvalidDate;
    }

    const seconds: u64 = @intCast(@divFloor(ms, 1000));
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();

    return std.fmt.allocPrint(arena, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

/// `2026-09-03T14:05`, what a `datetime-local` input holds, UTC.
pub fn datetime_local_text(arena: std.mem.Allocator, ms: i64) ![]const u8 {
    std.debug.assert(ms_max > 86_400_000);

    if (ms < 0 or ms >= ms_max) {
        return error.InvalidDate;
    }

    const seconds: u64 = @intCast(@divFloor(ms, 1000));
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();

    return std.fmt.allocPrint(arena, "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
    });
}

/// `YYYY-MM-DDTHH:MM`, with optional `:SS`, as milliseconds; null when malformed.
pub fn parse_datetime_local(text: []const u8) ?i64 {
    std.debug.assert(ms_max > 0);

    if (text.len != 16 and text.len != 19) {
        return null;
    }

    if (text[4] != '-' or text[7] != '-' or text[10] != 'T' or text[13] != ':') {
        return null;
    }

    for (text, 0..) |char, index| {
        if (index == 4 or index == 7 or index == 10 or index == 13 or index == 16) continue;
        if (!std.ascii.isDigit(char)) return null;
    }

    const year = std.fmt.parseInt(i64, text[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u32, text[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u32, text[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, text[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, text[14..16], 10) catch return null;

    if (text.len == 19 and text[16] != ':') {
        return null;
    }

    const second: i64 = if (text.len >= 19 and text[16] == ':')
        std.fmt.parseInt(i64, text[17..19], 10) catch return null
    else
        0;

    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 59) {
        return null;
    }

    if (!valid_day(year, month, day)) {
        return null;
    }

    const days = days_from_civil(year, month, day);
    const ms = ((days * 24 + hour) * 60 + minute) * 60_000 + second * 1000;

    return if (ms < 0 or ms >= ms_max) null else ms;
}

/// `YYYY-MM-DD`, what a `date` input holds, as the milliseconds its UTC day starts at;
/// null when malformed.
pub fn parse_date(text: []const u8) ?i64 {
    std.debug.assert(ms_max > 0);

    if (text.len != 10 or text[4] != '-' or text[7] != '-') {
        return null;
    }

    for (text, 0..) |char, index| {
        if (index == 4 or index == 7 or index == 10 or index == 13 or index == 16) continue;
        if (!std.ascii.isDigit(char)) return null;
    }

    const year = std.fmt.parseInt(i64, text[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u32, text[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u32, text[8..10], 10) catch return null;

    if (month < 1 or month > 12 or day < 1 or day > 31) {
        return null;
    }

    if (!valid_day(year, month, day)) {
        return null;
    }

    const ms = days_from_civil(year, month, day) * 86_400_000;

    return if (ms < 0 or ms >= ms_max) null else ms;
}

fn valid_day(year: i64, month: u32, day: u32) bool {
    std.debug.assert(month >= 1 and month <= 12);
    const lengths = [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const leap = @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
    const limit = lengths[month - 1] + @as(u32, if (month == 2 and leap) 1 else 0);
    return day >= 1 and day <= limit;
}

/// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's algorithm).
fn days_from_civil(year: i64, month: u32, day: u32) i64 {
    std.debug.assert(month >= 1 and month <= 12);
    std.debug.assert(day >= 1 and day <= 31);

    const shifted_year: i64 = if (month <= 2) year - 1 else year;
    const era = @divFloor(shifted_year, 400);
    const year_of_era = shifted_year - era * 400;
    const month_index: i64 = if (month > 2) month - 3 else month + 9;
    const day_of_year = @divFloor(153 * month_index + 2, 5) + day - 1;
    const leap_days = @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100);
    const day_of_era = year_of_era * 365 + leap_days + day_of_year;

    return era * 146_097 + day_of_era - 719_468;
}

test "datetime-local text round-trips through milliseconds" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("1970-01-01T00:00", try datetime_local_text(arena, 0));
    const noon = 1_788_393_600_000 + 12 * 3_600_000 + 5 * 60_000;
    try std.testing.expectEqualStrings("2026-09-03T12:05", try datetime_local_text(arena, noon));
    try std.testing.expectEqualStrings("2026-09-03 12:05:00", try datetime_text(arena, noon));
    try std.testing.expectEqualStrings(
        "2026-09-03 12:05:07",
        try datetime_text(
            arena,
            noon + 7999,
        ),
    );
    try std.testing.expectEqualStrings("1970-01-01 00:00:00", try datetime_text(arena, 0));
    try std.testing.expectEqual(@as(i64, noon), parse_datetime_local("2026-09-03T12:05").?);
    const with_seconds = parse_datetime_local("2026-09-03T12:05:07").?;
    try std.testing.expectEqual(@as(i64, noon + 7000), with_seconds);
    try std.testing.expectEqual(@as(i64, 0), parse_datetime_local("1970-01-01T00:00").?);
    const leap_day = parse_datetime_local("2000-02-29T00:00").?;
    try std.testing.expectEqual(@as(i64, 951_782_400_000), leap_day);
    try std.testing.expect(parse_datetime_local("2026-13-03T12:05") == null);
    try std.testing.expect(parse_datetime_local("2026-09-03 12:05") == null);
    try std.testing.expect(parse_datetime_local("") == null);
}

test "a date is the UTC day of the millisecond" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("1970-01-01", try date_text(arena, 0));
    try std.testing.expectEqualStrings("2026-09-03", try date_text(arena, 1_788_393_600_000));
    const last_ms = 1_788_393_600_000 + 86_399_999;
    try std.testing.expectEqualStrings("2026-09-03", try date_text(arena, last_ms));
    try std.testing.expectEqual(@as(i64, 1_788_393_600_000), parse_date("2026-09-03").?);
    try std.testing.expectEqual(@as(i64, 0), parse_date("1970-01-01").?);
    try std.testing.expect(parse_date("2026-09-03T00:00") == null);
    try std.testing.expect(parse_date("2026-00-03") == null);
    try std.testing.expect(parse_date("") == null);
}

test "invalid dates and out-of-range timestamps fail without trapping" {
    for ([_][]const u8{ "2025-02-29", "2000-02-30", "2026-04-31", "2026-+1-01" }) |text| {
        try std.testing.expect(parse_date(text) == null);
    }

    for ([_][]const u8{
        "2026-01-01T-1:00",
        "2026-01-01T00:00junk",
        "2026-02-30T00:00",
        "2026-01-01T00:00x00",
    }) |text| {
        try std.testing.expect(parse_datetime_local(text) == null);
    }

    for ([_]i64{ -1, ms_max, std.math.maxInt(i64) }) |ms| {
        try std.testing.expectError(error.InvalidDate, date_text(std.testing.allocator, ms));
        try std.testing.expectError(error.InvalidDate, datetime_text(std.testing.allocator, ms));
        try std.testing.expectError(
            error.InvalidDate,
            datetime_local_text(
                std.testing.allocator,
                ms,
            ),
        );
    }
}
