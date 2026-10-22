//! Filtering and ordering a list by a record's own fields: what each kind of field can be
//! filtered with, and how a clause on it (`field.total:more:4999`) becomes a condition on
//! the values index. Kinds fall into families; a family has its operators, each taking a
//! value written as text: one value, a range `low..high`, a JSON list, `yes`/`no`, a day
//! (`YYYY-MM-DD`, UTC) or a span back from now (`7d`, `2w`, `3m`, `1y`).

const std = @import("std");
const kinds = @import("kinds.zig");
const time = @import("../lib/time.zig");

pub const prefix = "field.";
pub const conditions_max: u32 = 8;
pub const list_len_max: u32 = 64;

pub const Error = error{Invalid};

pub const Family = enum { none, text, choice, yes_no, number, date, time, reference };

/// What an operator's value is, so the admin draws the right control for it.
pub const Takes = enum {
    text,
    choices,
    yes_no,
    number,
    number_range,
    day,
    day_range,
    span,
    records,
};

pub const Operator = struct {
    id: []const u8,
    label: []const u8,
    takes: Takes,
};

/// The store's operators, as `store/documents/list_filters.zig` names them.
pub const Test = enum {
    is,
    is_not,
    contains,
    not_contains,
    starts_with,
    less,
    more,
    at_most,
    at_least,
    between,
    within,
    outside,
    any_of,
    none_of,
    all_of,
};

/// One field's condition as the store takes it: the value in the column the kind stores.
pub const Condition = struct {
    field: []const u8,
    test_: Test,
    text: ?[]const u8 = null,
    int: ?i64 = null,
    real: ?f64 = null,
    ref: ?[]const u8 = null,
    text_high: ?[]const u8 = null,
    int_high: ?i64 = null,
    real_high: ?f64 = null,
    membership: bool = false,
    values_json: ?[]const u8 = null,
};

/// The family a kind belongs to: how its fields can be filtered and whether they order.
pub fn family_of(kind: kinds.Kind) Family {
    std.debug.assert(kind.id.len > 0);

    if (std.mem.eql(u8, kind.id, "password")) {
        return .none;
    }

    // `has.choices` says a field may list choices; a select is one that does.
    if (kind.control == .select) {
        return .choice;
    }

    if (std.mem.eql(u8, kind.id, "time")) {
        return .time;
    }

    return switch (kind.storage) {
        .text => .text,
        .bool => .yes_no,
        .int => if (kind.control == .datetime) .date else .number,
        .real => .number,
        .ref => .reference,
        .long, .none => .none,
    };
}

/// Whether a list can be ordered by fields of the family at all.
pub fn sortable(family: Family) bool {
    return switch (family) {
        .text, .choice, .yes_no, .number, .date, .time => true,
        .reference, .none => false,
    };
}

/// Whether fields of the family order a list unless their type says otherwise: amounts and
/// moments do; text, choices and yes/no do when the type asks.
pub fn sorts_by_default(family: Family) bool {
    return switch (family) {
        .number, .date, .time => true,
        .text, .choice, .yes_no, .reference, .none => false,
    };
}

const text_operators = [_]Operator{
    .{
        .id = "is",
        .label = "is",
        .takes = .text,
    },
    .{
        .id = "is_not",
        .label = "is not",
        .takes = .text,
    },
    .{
        .id = "contains",
        .label = "contains",
        .takes = .text,
    },
    .{
        .id = "not_contains",
        .label = "doesn't contain",
        .takes = .text,
    },
    .{
        .id = "starts_with",
        .label = "starts with",
        .takes = .text,
    },
};
const choice_operators = [_]Operator{
    .{
        .id = "any_of",
        .label = "is any of",
        .takes = .choices,
    },
    .{
        .id = "none_of",
        .label = "is none of",
        .takes = .choices,
    },
};
const yes_no_operators = [_]Operator{
    .{
        .id = "is",
        .label = "is",
        .takes = .yes_no,
    },
};
const number_operators = [_]Operator{
    .{
        .id = "is",
        .label = "is",
        .takes = .number,
    },
    .{
        .id = "is_not",
        .label = "is not",
        .takes = .number,
    },
    .{
        .id = "less",
        .label = "less than",
        .takes = .number,
    },
    .{
        .id = "more",
        .label = "more than",
        .takes = .number,
    },
    .{
        .id = "at_most",
        .label = "at most",
        .takes = .number,
    },
    .{
        .id = "at_least",
        .label = "at least",
        .takes = .number,
    },
    .{
        .id = "between",
        .label = "between",
        .takes = .number_range,
    },
};
const date_operators = [_]Operator{
    .{
        .id = "on",
        .label = "on",
        .takes = .day,
    },
    .{
        .id = "not_on",
        .label = "not on",
        .takes = .day,
    },
    .{
        .id = "before",
        .label = "before",
        .takes = .day,
    },
    .{
        .id = "after",
        .label = "after",
        .takes = .day,
    },
    .{
        .id = "before_inc",
        .label = "on or before",
        .takes = .day,
    },
    .{
        .id = "after_inc",
        .label = "on or after",
        .takes = .day,
    },
    .{
        .id = "in_the_past",
        .label = "in the past",
        .takes = .span,
    },
    .{
        .id = "over",
        .label = "over",
        .takes = .span,
    },
    .{
        .id = "between",
        .label = "between",
        .takes = .day_range,
    },
};
const time_operators = [_]Operator{
    .{
        .id = "before",
        .label = "before",
        .takes = .text,
    },
    .{
        .id = "after",
        .label = "after",
        .takes = .text,
    },
    .{
        .id = "between",
        .label = "between",
        .takes = .text,
    },
};
const reference_operators = [_]Operator{
    .{
        .id = "any_of",
        .label = "is any of",
        .takes = .records,
    },
    .{
        .id = "none_of",
        .label = "is none of",
        .takes = .records,
    },
};
const references_operators = reference_operators ++ [_]Operator{
    .{
        .id = "all_of",
        .label = "is all of",
        .takes = .records,
    },
};

/// The operators offered for a field, in the order offered; empty when it cannot be
/// filtered. A field holding several references also offers `all_of`.
pub fn operators_of(family: Family, many: bool) []const Operator {
    const offered: []const Operator = switch (family) {
        .text => &text_operators,
        .choice => &choice_operators,
        .yes_no => &yes_no_operators,
        .number => &number_operators,
        .date => &date_operators,
        .time => &time_operators,
        .reference => if (many) &references_operators else &reference_operators,
        .none => &.{},
    };

    std.debug.assert((offered.len == 0) == (family == .none));

    return offered;
}

/// The field a clause key names: `field.total` is `total`; null for a key that is not a
/// field's.
pub fn field_of(key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, key, prefix) or key.len == prefix.len) {
        return null;
    }

    return key[prefix.len..];
}

/// A clause on a field, read into the store's condition. `Invalid` for an operator the
/// field's family does not offer or a value it cannot read.
pub fn condition_of(
    field: []const u8,
    kind: kinds.Kind,
    many: bool,
    operator: []const u8,
    value: []const u8,
    now_ms: i64,
) Error!Condition {
    std.debug.assert(field.len > 0);
    std.debug.assert(now_ms >= 0);

    const family = family_of(kind);
    const offered = for (operators_of(family, many)) |candidate| {
        if (std.mem.eql(u8, candidate.id, operator)) {
            break candidate;
        }
    } else {
        return error.Invalid;
    };

    if (value.len == 0) {
        return error.Invalid;
    }

    return switch (family) {
        .text, .time => text_condition(field, offered.id, value),
        .choice => list_condition(field, offered.id, value, false),
        .reference => list_condition(field, offered.id, value, kind.has.taxonomy),
        .yes_no => yes_no_condition(field, value),
        .number => number_condition(field, kind.storage == .real, offered.id, value),
        .date => date_condition(field, offered.id, value, now_ms),
        .none => error.Invalid,
    };
}

fn test_of(operator: []const u8) Error!Test {
    std.debug.assert(operator.len > 0);

    return std.meta.stringToEnum(Test, operator) orelse error.Invalid;
}

fn text_condition(field: []const u8, operator: []const u8, value: []const u8) Error!Condition {
    std.debug.assert(value.len > 0);

    if (std.mem.eql(u8, operator, "before") or std.mem.eql(u8, operator, "after")) {
        return .{
            .field = field,
            .test_ = if (operator[0] == 'b') .less else .more,
            .text = value,
        };
    }

    if (std.mem.eql(u8, operator, "between")) {
        const ends = try range_of(value);

        return .{
            .field = field,
            .test_ = .between,
            .text = ends[0],
            .text_high = ends[1],
        };
    }

    return .{
        .field = field,
        .test_ = try test_of(operator),
        .text = value,
    };
}

fn list_condition(
    field: []const u8,
    operator: []const u8,
    value: []const u8,
    membership: bool,
) Error!Condition {
    std.debug.assert(value.len > 0);

    if (value[0] != '[' or value[value.len - 1] != ']') {
        return error.Invalid;
    }

    return .{
        .field = field,
        .test_ = try test_of(operator),
        .membership = membership,
        .values_json = value,
    };
}

fn yes_no_condition(field: []const u8, value: []const u8) Error!Condition {
    std.debug.assert(field.len > 0);

    const yes = std.mem.eql(u8, value, "yes");

    if (!yes and !std.mem.eql(u8, value, "no")) {
        return error.Invalid;
    }

    return .{
        .field = field,
        .test_ = .is,
        .int = @intFromBool(yes),
    };
}

fn number_condition(
    field: []const u8,
    real: bool,
    operator: []const u8,
    value: []const u8,
) Error!Condition {
    std.debug.assert(field.len > 0);

    const ranged = std.mem.eql(u8, operator, "between");
    const ends: [2][]const u8 = if (ranged) try range_of(value) else .{ value, value };
    var condition: Condition = .{
        .field = field,
        .test_ = try test_of(operator),
    };

    if (real) {
        condition.real = std.fmt.parseFloat(f64, ends[0]) catch return error.Invalid;
        condition.real_high = if (ranged) std.fmt.parseFloat(f64, ends[1]) catch {
            return error.Invalid;
        } else null;
    } else {
        condition.int = std.fmt.parseInt(i64, ends[0], 10) catch return error.Invalid;
        condition.int_high = if (ranged) std.fmt.parseInt(i64, ends[1], 10) catch {
            return error.Invalid;
        } else null;
    }

    return condition;
}

const day_ms_count: i64 = 86_400_000;

/// A date clause as bounds on the stored milliseconds: a day is `[start, next start)`.
fn date_condition(
    field: []const u8,
    operator: []const u8,
    value: []const u8,
    now_ms: i64,
) Error!Condition {
    std.debug.assert(field.len > 0);
    std.debug.assert(now_ms >= 0);

    const named = std.meta.stringToEnum(enum {
        on,
        not_on,
        before,
        after,
        before_inc,
        after_inc,
        in_the_past,
        over,
        between,
    }, operator) orelse return error.Invalid;

    if (named == .in_the_past or named == .over) {
        const since = try back_from(now_ms, value);

        return .{
            .field = field,
            .test_ = if (named == .over) .less else .at_least,
            .int = since,
        };
    }

    if (named == .between) {
        const ends = try range_of(value);
        const low = time.parse_date(ends[0]) orelse return error.Invalid;
        const high = time.parse_date(ends[1]) orelse return error.Invalid;

        return .{
            .field = field,
            .test_ = .within,
            .int = low,
            .int_high = high + day_ms_count,
        };
    }

    const start = time.parse_date(value) orelse return error.Invalid;
    const next = start + day_ms_count;
    const bounds: struct {
        Test,
        i64,
        ?i64,
    } = switch (named) {
        .on => .{ .within, start, next },
        .not_on => .{ .outside, start, next },
        .before => .{ .less, start, null },
        .before_inc => .{ .less, next, null },
        .after => .{ .at_least, next, null },
        .after_inc => .{ .at_least, start, null },
        .in_the_past, .over, .between => unreachable,
    };

    return .{
        .field = field,
        .test_ = bounds[0],
        .int = bounds[1],
        .int_high = bounds[2],
    };
}

/// `7d`, `2w`, `3m`, `1y` back from now: months and years by the calendar, the day
/// clamped to the month's last (31 March less a month is 28 or 29 February).
pub fn back_from(now_ms: i64, span: []const u8) Error!i64 {
    std.debug.assert(now_ms >= 0);

    if (span.len < 2 or span.len > 6) {
        return error.Invalid;
    }

    const count = std.fmt.parseInt(u32, span[0 .. span.len - 1], 10) catch return error.Invalid;

    if (count == 0 or count > 1200) {
        return error.Invalid;
    }

    return switch (span[span.len - 1]) {
        'd' => @max(0, now_ms - @as(i64, count) * day_ms_count),
        'w' => @max(0, now_ms - @as(i64, count) * 7 * day_ms_count),
        'm' => months_back(now_ms, count),
        'y' => months_back(now_ms, count * 12),
        else => error.Invalid,
    };
}

fn months_back(now_ms: i64, months: u32) i64 {
    std.debug.assert(now_ms >= 0);
    std.debug.assert(months > 0);

    const seconds: u64 = @intCast(@divFloor(now_ms, 1000));
    const day = std.time.epoch.EpochSeconds{
        .secs = seconds,
    };
    const epoch_day = day.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const total = @as(i64, year_day.year) * 12 + (@intFromEnum(month_day.month) - 1) - months;

    if (total < 1970 * 12) {
        return 0;
    }

    const year: u16 = @intCast(@divFloor(total, 12));
    const month: u4 = @intCast(@mod(total, 12) + 1);
    const last = std.time.epoch.getDaysInMonth(year, @enumFromInt(month));
    const day_of_month = @min(@as(u32, month_day.day_index) + 1, last);
    var text: [10]u8 = undefined;
    const written = std.fmt.bufPrint(&text, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year,
        month,
        day_of_month,
    }) catch unreachable;
    const start = time.parse_date(written) orelse unreachable;

    return start + @mod(now_ms, day_ms_count);
}

/// `low..high`, both given.
fn range_of(value: []const u8) Error![2][]const u8 {
    std.debug.assert(value.len > 0);

    const dots = std.mem.indexOf(u8, value, "..") orelse return error.Invalid;
    const low = value[0..dots];
    const high = value[dots + 2 ..];

    if (low.len == 0 or high.len == 0) {
        return error.Invalid;
    }

    return .{ low, high };
}

const testing = std.testing;
const test_now_ms: i64 = 1_792_454_400_000; // 2026-10-20T00:00:00Z

fn core_kind(id: []const u8) kinds.Kind {
    return kinds.Core.find_kind(id).?;
}

test "each kind falls in its family; long text and passwords are not filtered" {
    try testing.expectEqual(Family.text, family_of(core_kind("string")));
    try testing.expectEqual(Family.choice, family_of(core_kind("select")));
    try testing.expectEqual(Family.yes_no, family_of(core_kind("boolean")));
    try testing.expectEqual(Family.number, family_of(core_kind("money")));
    try testing.expectEqual(Family.number, family_of(core_kind("integer")));
    try testing.expectEqual(Family.date, family_of(core_kind("datetime")));
    try testing.expectEqual(Family.time, family_of(core_kind("time")));
    try testing.expectEqual(Family.reference, family_of(core_kind("reference")));
    try testing.expectEqual(Family.none, family_of(core_kind("richtext")));
    try testing.expectEqual(Family.none, family_of(core_kind("password")));
    try testing.expect(!sortable(.reference));
    try testing.expectEqual(@as(usize, 3), operators_of(.reference, true).len);
}

test "clauses become conditions; wrong operators and values are refused" {
    const money = core_kind("money");
    const datetime = core_kind("datetime");
    const total = try condition_of("total", money, false, "between", "100..500", test_now_ms);
    try testing.expectEqual(Test.between, total.test_);
    try testing.expectEqual(@as(i64, 500), total.int_high.?);

    const on = try condition_of("placed", datetime, false, "on", "2026-10-19", test_now_ms);
    try testing.expectEqual(Test.within, on.test_);
    try testing.expectEqual(test_now_ms - day_ms_count, on.int.?);
    try testing.expectEqual(test_now_ms, on.int_high.?);

    const recent = try condition_of("placed", datetime, false, "in_the_past", "1m", test_now_ms);
    try testing.expectEqual(Test.at_least, recent.test_);
    try testing.expectEqual(test_now_ms - 30 * day_ms_count, recent.int.?);

    const paid = try condition_of("paid", core_kind("boolean"), false, "is", "yes", test_now_ms);
    try testing.expectEqual(@as(i64, 1), paid.int.?);

    const string = core_kind("string");
    const select = core_kind("select");
    const richtext = core_kind("richtext");

    try testing.expectError(error.Invalid, condition_of("name", string, false, "more", "a", 0));
    try testing.expectError(error.Invalid, condition_of("total", money, false, "is", "lots", 0));
    try testing.expectError(error.Invalid, condition_of("size", select, false, "any_of", "s", 0));
    try testing.expectError(error.Invalid, condition_of("body", richtext, false, "is", "a", 0));
    try testing.expectEqualStrings("total", field_of("field.total").?);
    try testing.expect(field_of("status") == null);
}

test "months back by the calendar, the day clamped to the month" {
    const march_31 = time.parse_date("2026-03-31").?;
    const back = try back_from(march_31, "1m");
    try testing.expectEqual(time.parse_date("2026-02-28").?, back);
    try testing.expectEqual(time.parse_date("2025-03-31").?, try back_from(march_31, "1y"));
    try testing.expectError(error.Invalid, back_from(march_31, "0d"));
    try testing.expectError(error.Invalid, back_from(march_31, "3x"));
}
