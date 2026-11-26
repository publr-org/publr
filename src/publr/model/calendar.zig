//! Days on the calendar: whole days between two dates, months and years added with the
//! month-end clamp (31 January and a month is 28 or 29 February). A month is never 30 days.
const std = @import("std");

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
