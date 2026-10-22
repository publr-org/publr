//! A list's conditions on records' own fields: each filter one operator over the values
//! index (`v`), or over the term memberships (`m`) for a terms field, ancestors included.
//! Every value is bound; the text written holds only literals and placeholder numbers.

const std = @import("std");
const db = @import("../../lib/db.zig");

pub const filters_max: u32 = 8;

pub const Operator = enum {
    is,
    is_not,
    contains,
    not_contains,
    starts_with,
    less,
    more,
    at_most,
    at_least,
    /// `low <= value <= high`.
    between,
    /// `low <= value < high`: a day, a span of time.
    within,
    /// Not within.
    outside,
    any_of,
    none_of,
    all_of,
};

/// One field's condition. The value is the one of `text`, `int`, `real` or `ref` the field's
/// kind stores; `any_of`, `none_of` and `all_of` take `values_json` (a JSON array) instead.
pub const Filter = struct {
    field: []const u8,
    operator: Operator = .is,
    text: ?[]const u8 = null,
    int: ?i64 = null,
    real: ?f64 = null,
    ref: ?[]const u8 = null,
    /// The upper end for `between`, `within` and `outside`, of the value's kind.
    text_high: ?[]const u8 = null,
    int_high: ?i64 = null,
    real_high: ?f64 = null,
    /// A terms field: matched through the membership index, ancestors included.
    membership: bool = false,
    values_json: ?[]const u8 = null,
};

pub const Error = error{OutOfMemory};

/// Whether a filter's operator and values fit together.
pub fn valid(filter: Filter) bool {
    std.debug.assert(filter.field.len > 0);

    const listed = filter.values_json != null;
    const ranged = filter.int_high != null or filter.real_high != null or
        filter.text_high != null;
    const textual = switch (filter.operator) {
        .contains, .not_contains, .starts_with => true,
        else => false,
    };

    if (filter.membership and !(filter.operator == .is or listing(filter.operator))) {
        return false;
    }

    if (textual and filter.text == null) {
        return false;
    }

    return listed == listing(filter.operator) and ranged == range(filter.operator);
}

/// How many placeholders a filter takes: its field, its value, and a range's upper end.
pub fn binds_of(filter: Filter) u32 {
    std.debug.assert(filter.field.len > 0);

    return if (range(filter.operator)) 3 else 2;
}

fn listing(operator: Operator) bool {
    return operator == .any_of or operator == .none_of or operator == .all_of;
}

fn range(operator: Operator) bool {
    return operator == .between or operator == .within or operator == .outside;
}

/// The operator a negative one excludes: `is_not` keeps what `is` does not.
fn positive_of(operator: Operator) Operator {
    const positive: Operator = switch (operator) {
        .is_not => .is,
        .not_contains => .contains,
        .outside => .within,
        .none_of => .any_of,
        else => operator,
    };

    std.debug.assert(positive != .is_not and positive != .not_contains);
    std.debug.assert(positive != .outside and positive != .none_of);

    return positive;
}

pub fn Writer(comptime values: []const u8, comptime assignments: ?[]const u8) type {
    return struct {
        /// One filter on the copy in `slot`, as ` AND ...`; the field is `?{field}`, its
        /// value (and a range's upper end) the placeholders after it. A record without the
        /// value matches every negative operator.
        pub fn write(
            writer: *std.Io.Writer,
            filter: Filter,
            slot: []const u8,
            one_type: bool,
            field: u32,
        ) Error!void {
            std.debug.assert(valid(filter));
            std.debug.assert(field > 1);

            const negative = positive_of(filter.operator) != filter.operator;
            const not = if (negative) "NOT " else "";
            const column = if (filter.membership) "m.term" else "v.value";

            if (filter.operator == .all_of) {
                return write_all_of(writer, filter.membership, slot, field);
            }

            if (filter.membership) {
                const from = assignments orelse unreachable;

                try print(writer, " AND {s}EXISTS (SELECT 1 FROM {s} m WHERE m.record = r.id " ++
                    "AND m.field = ?{d} AND m.slot = {s} AND ", .{ not, from, field, slot });
            } else if (one_type) {
                try print(writer, " AND r.id {s}IN (SELECT v.record FROM {s} v WHERE " ++
                    "v.type_id = ?1 AND v.field = ?{d} AND v.slot = {s} " ++
                    "AND v.kind <> 'long' AND ", .{ not, values, field, slot });
            } else {
                try print(writer, " AND {s}EXISTS (SELECT 1 FROM {s} v WHERE v.record = r.id " ++
                    "AND v.type_id = r.type_id AND v.field = ?{d} AND v.slot = {s} " ++
                    "AND v.kind <> 'long' AND ", .{ not, values, field, slot });
            }

            try write_test(writer, positive_of(filter.operator), column, field + 1);
            try print(writer, ")", .{});
        }

        /// Every one of the listed values held: as many distinct matches as values listed.
        fn write_all_of(
            writer: *std.Io.Writer,
            membership: bool,
            slot: []const u8,
            field: u32,
        ) Error!void {
            std.debug.assert(field > 1);
            std.debug.assert(slot.len > 0);

            const listed = field + 1;

            if (membership) {
                const from = assignments orelse unreachable;

                return print(writer, " AND (SELECT COUNT(DISTINCT m.term) FROM {s} m " ++
                    "WHERE m.record = r.id AND m.field = ?{d} AND m.slot = {s} AND m.term IN " ++
                    "(SELECT value FROM json_each(?{d}))) = json_array_length(?{d})", .{
                    from, field, slot, listed, listed,
                });
            }

            try print(writer, " AND (SELECT COUNT(DISTINCT v.value) FROM {s} v " ++
                "WHERE v.record = r.id AND v.field = ?{d} AND v.slot = {s} " ++
                "AND v.kind <> 'long' AND v.value IN (SELECT value FROM json_each(?{d}))) = " ++
                "json_array_length(?{d})", .{ values, field, slot, listed, listed });
        }
    };
}

/// The test on one row's `column`, its value at `?{value}` (and a range's end after it).
fn write_test(
    writer: *std.Io.Writer,
    operator: Operator,
    column: []const u8,
    value: u32,
) Error!void {
    std.debug.assert(value > 2);
    std.debug.assert(positive_of(operator) == operator);

    const args = .{ column, value };

    switch (operator) {
        .is => try print(writer, "{s} = ?{d}", args),
        .contains => try print(writer, "instr(lower({s}), lower(?{d})) > 0", args),
        .starts_with => try print(writer, "lower(substr({s}, 1, length(?{d}))) = lower(?{d})", .{
            column, value, value,
        }),
        .less => try print(writer, "{s} < ?{d}", args),
        .more => try print(writer, "{s} > ?{d}", args),
        .at_most => try print(writer, "{s} <= ?{d}", args),
        .at_least => try print(writer, "{s} >= ?{d}", args),
        .between => try print(writer, "{s} >= ?{d} AND {s} <= ?{d}", .{
            column, value, column, value + 1,
        }),
        .within => try print(writer, "{s} >= ?{d} AND {s} < ?{d}", .{
            column, value, column, value + 1,
        }),
        .any_of => try print(writer, "{s} IN (SELECT value FROM json_each(?{d}))", args),
        .is_not, .not_contains, .outside, .none_of, .all_of => unreachable,
    }
}

fn print(writer: *std.Io.Writer, comptime format: []const u8, args: anytype) Error!void {
    writer.print(format, args) catch return error.OutOfMemory;
}

/// Binds a filter's field and values from `bind_index` on; answers the next number.
pub fn bind(select: *db.Statement, filter: Filter, bind_index: u31) db.Error!u31 {
    std.debug.assert(valid(filter));
    std.debug.assert(bind_index > 1);

    const value = bind_index + 1;

    try select.bind_text(bind_index, filter.field);

    if (filter.values_json) |given| {
        try select.bind_text(value, given);
    } else if (filter.text) |text| {
        try select.bind_text(value, text);
    } else if (filter.real) |real| {
        try select.bind_real(value, real);
    } else if (filter.ref) |ref| {
        try select.bind_text(value, ref);
    } else {
        try select.bind_int(value, filter.int orelse 0);
    }

    if (filter.text_high) |high| {
        try select.bind_text(value + 1, high);
    } else if (filter.real_high) |high| {
        try select.bind_real(value + 1, high);
    } else if (filter.int_high) |high| {
        try select.bind_int(value + 1, high);
    }

    return bind_index + @as(u31, @intCast(binds_of(filter)));
}

test "operators and values fit, or the filter is refused" {
    try std.testing.expect(valid(.{
        .field = "views",
        .operator = .between,
        .int = 1,
        .int_high = 9,
    }));
    try std.testing.expect(!valid(.{
        .field = "views",
        .operator = .between,
        .int = 1,
    }));
    try std.testing.expect(!valid(.{
        .field = "tags",
        .operator = .contains,
        .membership = true,
        .text = "a",
    }));
    try std.testing.expect(!valid(.{
        .field = "tags",
        .operator = .any_of,
    }));
    try std.testing.expectEqual(@as(u32, 3), binds_of(.{
        .field = "at",
        .operator = .within,
        .int = 0,
        .int_high = 1,
    }));
}
