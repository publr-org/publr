//! Calendar arithmetic on a site's clock: the date a moment falls on, the start of a day,
//! months and years added with the month-end clamp (31 January and a month is 28 or 29
//! February), and whole days between two dates. A month is never 30 days. Pure: a zone is
//! its POSIX rule (`lib/zone.zig`), summer time included.
const std = @import("std");
const zone = @import("../lib/zone.zig");

const day_ms: i64 = 24 * 60 * 60 * 1000;

/// A day on the calendar.
pub const Date = struct {
    year: i32,
    /// 1 to 12.
    month: u8,
    /// 1 to the month's last day.
    day: u8,

    /// Whole days from this date to `other`: the nights between a check-in and a check-out;
    /// negative when `other` comes first.
    pub fn days_until(date: Date, other: Date) i64 {
        std.debug.assert(valid(date));
        std.debug.assert(valid(other));

        return days_of(other) - days_of(date);
    }

    pub fn add_days(date: Date, days: i64) Date {
        std.debug.assert(valid(date));
        std.debug.assert(days > -(1 << 30) and days < (1 << 30));

        return date_of(days_of(date) + days);
    }

    /// `months` later (earlier when negative), on the same day, or the month's last when
    /// it has fewer days.
    pub fn add_months(date: Date, months: i64) Date {
        std.debug.assert(valid(date));
        std.debug.assert(months > -(1 << 20) and months < (1 << 20));

        const index = @as(i64, date.year) * 12 + (date.month - 1) + months;
        const year: i32 = @intCast(@divFloor(index, 12));
        const month: u8 = @intCast(@mod(index, 12) + 1);

        return .{
            .year = year,
            .month = month,
            .day = @min(date.day, days_in_month(year, month)),
        };
    }

    pub fn add_years(date: Date, years: i64) Date {
        std.debug.assert(valid(date));
        std.debug.assert(years > -(1 << 16) and years < (1 << 16));

        return date.add_months(years * 12);
    }

    pub fn before(date: Date, other: Date) bool {
        std.debug.assert(valid(date));
        std.debug.assert(valid(other));

        return days_of(date) < days_of(other);
    }
};

pub fn valid(date: Date) bool {
    std.debug.assert(date.year > -(1 << 20));

    return date.month >= 1 and date.month <= 12 and date.day >= 1 and
        date.day <= days_in_month(date.year, date.month);
}

pub fn days_in_month(year: i32, month: u8) u8 {
    std.debug.assert(month >= 1 and month <= 12);
    std.debug.assert(year > -(1 << 20));

    const lengths = [12]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const leap = @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);

    return if (month == 2 and leap) 29 else lengths[month - 1];
}

/// Days since 1 January 1970.
pub fn days_of(date: Date) i64 {
    std.debug.assert(date.month >= 1 and date.month <= 12);
    std.debug.assert(date.day >= 1 and date.day <= 31);

    const year: i64 = if (date.month <= 2) @as(i64, date.year) - 1 else date.year;
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const month: i64 = date.month;
    const shifted: i64 = if (month > 2) month - 3 else month + 9;
    const day_of_year = @divFloor(153 * shifted + 2, 5) + date.day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;

    return era * 146097 + day_of_era - 719468;
}

/// The date `days` after 1 January 1970.
pub fn date_of(days: i64) Date {
    std.debug.assert(days > -(1 << 40) and days < (1 << 40));

    const shifted = days + 719468;
    const era = @divFloor(shifted, 146097);
    const day_of_era = shifted - era * 146097;
    const year_of_era = @divFloor(day_of_era - @divFloor(day_of_era, 1460) +
        @divFloor(day_of_era, 36524) - @divFloor(day_of_era, 146096), 365);
    const day_of_year = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100));
    const month_index = @divFloor(5 * day_of_year + 2, 153);
    const day: u8 = @intCast(day_of_year - @divFloor(153 * month_index + 2, 5) + 1);
    const month: u8 = @intCast(if (month_index < 10) month_index + 3 else month_index - 9);
    const year = year_of_era + era * 400 + @as(i64, if (month <= 2) 1 else 0);
    const date: Date = .{
        .year = @intCast(year),
        .month = month,
        .day = day,
    };

    std.debug.assert(valid(date));

    return date;
}

/// The date a moment falls on, on the clock of the zone with `rule`.
pub fn local_date(rule: []const u8, utc_ms: i64) Date {
    std.debug.assert(rule.len <= 128);

    const local_ms = utc_ms + zone.offset_ms(rule, utc_ms);

    return date_of(@divFloor(local_ms, day_ms));
}

/// The moment `date` starts on the clock of the zone with `rule`.
pub fn start_of(rule: []const u8, date: Date) i64 {
    std.debug.assert(rule.len <= 128);
    std.debug.assert(valid(date));

    return zone.utc_of(rule, days_of(date) * day_ms);
}

/// The time of day a moment shows on the zone's clock, in ms since its midnight.
pub fn time_of_day_ms(rule: []const u8, utc_ms: i64) i64 {
    std.debug.assert(rule.len <= 128);

    const local_ms = utc_ms + zone.offset_ms(rule, utc_ms);

    return @mod(local_ms, day_ms);
}

/// A moment `months` later on the zone's clock: the same time of day, on the same day of
/// the month or its last.
pub fn add_months(rule: []const u8, utc_ms: i64, months: i64) i64 {
    std.debug.assert(rule.len <= 128);
    std.debug.assert(months > -(1 << 20) and months < (1 << 20));

    const date = local_date(rule, utc_ms).add_months(months);
    const local_ms = days_of(date) * day_ms + time_of_day_ms(rule, utc_ms);

    return zone.utc_of(rule, local_ms);
}

/// The first yearly return of `utc_ms` on the zone's clock (its own year counted) whose
/// moment plus `offset_ms` is after `now_ms`: a birthday's next one, 29 February on 28 February
/// in other years.
pub fn next_yearly(rule: []const u8, utc_ms: i64, offset_ms: i64, now_ms: i64) i64 {
    std.debug.assert(rule.len <= 128);
    std.debug.assert(offset_ms > -366 * day_ms and offset_ms < 366 * day_ms);

    const years_between = local_date(rule, now_ms).year - local_date(rule, utc_ms).year;
    const first: i64 = @max(years_between - 1, 0);
    var years = first;

    // The offset is under a year: one of the next three returns is after `now_ms`.
    while (years < first + 3) : (years += 1) {
        const moment = add_months(rule, utc_ms, years * 12);

        if (moment + offset_ms > now_ms) {
            return moment;
        }
    }

    unreachable;
}

test "dates: days since 1970 both ways, month ends clamped, leap years" {
    const first: Date = .{
        .year = 1970,
        .month = 1,
        .day = 1,
    };
    const end_of_january: Date = .{
        .year = 2024,
        .month = 1,
        .day = 31,
    };

    try std.testing.expectEqual(@as(i64, 0), days_of(first));
    try std.testing.expectEqual(end_of_january, date_of(days_of(end_of_january)));
    try std.testing.expectEqual(@as(u8, 29), end_of_january.add_months(1).day);
    try std.testing.expectEqual(@as(u8, 28), end_of_january.add_years(1).add_months(1).day);
    try std.testing.expectEqual(@as(u8, 3), end_of_january.add_months(2).month);
    try std.testing.expectEqual(@as(u8, 12), end_of_january.add_months(-1).month);
    try std.testing.expectEqual(@as(i32, 2023), end_of_january.add_months(-1).year);

    const leap_day: Date = .{
        .year = 2024,
        .month = 2,
        .day = 29,
    };

    try std.testing.expectEqual(@as(u8, 28), leap_day.add_years(1).day);
    try std.testing.expectEqual(@as(i64, 29), end_of_january.days_until(leap_day));
    try std.testing.expectEqual(@as(i64, -29), leap_day.days_until(end_of_january));
    try std.testing.expect(!valid(.{
        .year = 2023,
        .month = 2,
        .day = 29,
    }));
}

test "a moment on a zone's clock: its date, its day's start, a month later" {
    const warsaw = "CET-1CEST,M3.5.0,M10.5.0/3";
    // 2024-03-30 23:30 UTC is 31 March 01:30 in Warsaw (winter time still).
    const late: i64 = (days_of(.{
        .year = 2024,
        .month = 3,
        .day = 30,
    }) * day_ms) + (23 * 60 + 30) * 60 * 1000;
    const date = local_date(warsaw, late);

    try std.testing.expectEqual(@as(u8, 31), date.day);

    // The day starts at midnight in Warsaw: 23:00 UTC the day before.
    const midnight = start_of(warsaw, date);

    try std.testing.expectEqual(late - 30 * 60 * 1000, midnight);

    // A month later is 30 April, the same time of day on the clock (summer time by then).
    const later = add_months(warsaw, late, 1);

    try std.testing.expectEqual(@as(u8, 30), local_date(warsaw, later).day);
    try std.testing.expectEqual(time_of_day_ms(warsaw, late), time_of_day_ms(warsaw, later));
    try std.testing.expectEqual(late, add_months("UTC0", late, 0));
}

test "a yearly moment: its next return after now, the offset counted, leap day clamped" {
    const utc = "UTC0";
    const born = days_of(.{
        .year = 1990,
        .month = 6,
        .day = 15,
    }) * day_ms;
    const now = days_of(.{
        .year = 2026,
        .month = 6,
        .day = 10,
    }) * day_ms;
    const this_year = days_of(.{
        .year = 2026,
        .month = 6,
        .day = 15,
    }) * day_ms;

    try std.testing.expectEqual(this_year, next_yearly(utc, born, 0, now));
    // A week before it has gone by: next year's.
    try std.testing.expectEqual(
        add_months(utc, this_year, 12),
        next_yearly(utc, born, -7 * day_ms, now),
    );
    // Not before its own year.
    try std.testing.expectEqual(this_year, next_yearly(utc, this_year, 0, now - 400 * day_ms));

    const leap_day = days_of(.{
        .year = 2024,
        .month = 2,
        .day = 29,
    }) * day_ms;
    const in_2025 = local_date(utc, next_yearly(utc, leap_day, 0, leap_day + day_ms));

    try std.testing.expectEqual(@as(u8, 28), in_2025.day);
    try std.testing.expectEqual(@as(i32, 2025), in_2025.year);
}
