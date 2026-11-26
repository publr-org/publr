//! Calendar arithmetic on a site's clock: the date a moment falls on, the start of a day,
//! months and years added with the month-end clamp (31 January and a month is 28 or 29
//! February), and whole days between two dates. A month is never 30 days. Pure: a zone is
//! its POSIX rule (`lib/zone.zig`), summer time included.
const std = @import("std");
const zone = @import("../lib/zone.zig");

const day_ms: i64 = 24 * 60 * 60 * 1000;

const public = @import("../publr/model/calendar.zig");

pub const Date = public.Date;
pub const valid = public.valid;
pub const days_in_month = public.days_in_month;
pub const days_of = public.days_of;
pub const date_of = public.date_of;

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
