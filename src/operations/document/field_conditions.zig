//! A list's clauses on the records' own fields (`field.total:more:4999`) and its order by
//! one (`total`, `-total` descending), read against the one definition the list covers.

const std = @import("std");
const model = @import("../../model.zig");
const registry = @import("../../server/registry.zig");
const store = @import("../../store.zig");

const Def = store.definitions.Def;
const Filter = store.documents.Filter;
const field_filter = model.field_filter;

pub const Error = error{ Invalid, OutOfMemory };

/// Whether a clause names one of the record's own fields, rather than a filter of core's or
/// a plugin's.
pub fn is_field(clause: []const u8) bool {
    return std.mem.startsWith(u8, clause, field_filter.prefix);
}

/// The clauses on fields, as the store's filters, after `first` (a slug or a field match
/// asked for on its own). A clause on a field needs the list to cover one definition.
pub fn filters_of(
    arena: std.mem.Allocator,
    def: ?Def,
    first: ?Filter,
    clauses: []const []const u8,
    now_ms: i64,
) Error![]const Filter {
    std.debug.assert(now_ms >= 0);
    std.debug.assert(clauses.len <= model.filter.filters_max);

    var filters: std.ArrayList(Filter) = .empty;

    if (first) |given| {
        filters.append(arena, given) catch return error.OutOfMemory;
    }

    for (clauses) |text| {
        if (!is_field(text)) {
            continue;
        }

        const single = def orelse return error.Invalid;
        const clause = model.filter.parse_clause(text) orelse return error.Invalid;
        const name = field_filter.field_of(clause.key) orelse return error.Invalid;
        const found = model.document.find_path(single.fields, name) orelse return error.Invalid;
        const kind = model.kinds.lookup(registry.Kinds.all, found.kind);
        const condition = field_filter.condition_of(
            name,
            kind,
            found.many,
            clause.operator,
            clause.value,
            now_ms,
        ) catch return error.Invalid;

        if (filters.items.len == field_filter.conditions_max) {
            return error.Invalid;
        }

        filters.append(arena, filter_of(condition)) catch return error.OutOfMemory;
    }

    return filters.items;
}

fn filter_of(condition: field_filter.Condition) Filter {
    std.debug.assert(condition.field.len > 0);

    return .{
        .field = condition.field,
        .operator = std.meta.stringToEnum(
            store.documents.Operator,
            @tagName(condition.test_),
        ).?,
        .text = condition.text,
        .int = condition.int,
        .real = condition.real,
        .ref = condition.ref,
        .text_high = condition.text_high,
        .int_high = condition.int_high,
        .real_high = condition.real_high,
        .membership = condition.membership,
        .values_json = condition.values_json,
    };
}

/// `total` or `-total`: the list ordered by a field of its one definition whose kind orders.
pub fn sort_of(def: ?Def, given: ?[]const u8) Error!?store.documents.Sort {
    const text = given orelse return null;
    const descending = std.mem.startsWith(u8, text, "-");
    const name = if (descending) text[1..] else text;

    std.debug.assert(text.len <= 1024);

    if (name.len == 0) {
        return error.Invalid;
    }

    const single = def orelse return error.Invalid;
    const found = model.document.find_path(single.fields, name) orelse return error.Invalid;
    const kind = model.kinds.lookup(registry.Kinds.all, found.kind);

    if (found.many or !field_filter.sortable(field_filter.family_of(kind))) {
        return error.Invalid;
    }

    return .{
        .field = name,
        .descending = descending,
    };
}
