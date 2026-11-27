//! The content list's pills on a type's own fields (`Total is more than 4999`) and the
//! Filter menu's entries for them, from what the type offers (`view.default`): each field's
//! operators, and a value picked the way the operator takes it.
const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const model = @import("../../../model.zig");
const types = @import("../../../operations/content_type.zig");
const record_operations = @import("../../../operations/record.zig");
const view_default = @import("../../../operations/view_default.zig");
const list = @import("list.zig");
const pills = @import("pills.zig");
const view_offer = @import("view_offer.zig");

const Error = admin.Error;
const views = admin.views;
const Clause = model.filter.Clause;
const Page = list.Page;
const Pill = views.ContentList.FiltersItem;
const Option = views.ContentList.OptionsItem;
const Operator = views.ContentList.OperatorsItem;
const Adder = views.ContentList.Add_filtersItem;

/// Records a reference pill offers to pick from.
const records_offered_max: u32 = 50;

/// The pill of the field clause at `index`; null when the type does not offer the field.
pub fn pill(page: *const Page, clause: Clause, index: u32) Error!?Pill {
    std.debug.assert(clause.key.len > model.field_filter.prefix.len);

    const offer = page.offer orelse return null;
    const name = model.field_filter.field_of(clause.key) orelse return null;
    const field = view_offer.filterable(offer, name) orelse return null;
    const operator = view_offer.operator_of(offer, name, clause.operator) orelse return null;
    const session = page.session;
    const arena = session.arena;
    const rest = try model.view.without(arena, page.effective, index);
    const def = try field_def(page, name);
    const options = try options_of(page, clause, index, operator, def);
    const parts = parts_of(operator.takes, clause.value);

    return .{
        .id = try std.fmt.allocPrint(arena, "filter-field-{s}", .{name}),
        .name = clause.key,
        .label = try session.declared(field.label),
        .operator = try session.declared(operator.label),
        .operator_id = operator.id,
        .operator_name = try std.fmt.allocPrint(arena, "{s}_operator", .{clause.key}),
        .operators = try operators_of(page, clause, index, field),
        .value = try value_text(page, operator.takes, clause.value, options),
        .value_kind = kind_of(operator.takes),
        .day = if (single(operator.takes)) clause.value else "",
        .low = parts.low,
        .high = parts.high,
        .low_name = try std.fmt.allocPrint(arena, "{s}_from", .{clause.key}),
        .high_name = try std.fmt.allocPrint(arena, "{s}_to", .{clause.key}),
        .count = parts.count,
        .unit = parts.unit,
        .count_name = try std.fmt.allocPrint(arena, "{s}_count", .{clause.key}),
        .unit_name = try std.fmt.allocPrint(arena, "{s}_unit", .{clause.key}),
        .options = options,
        .carried = try pills.pairs_of(views.ContentList.CarriedItem, page, rest),
        .remove_href = try page.href(rest),
        .reset_href = "",
        .searchable = std.mem.eql(u8, operator.takes, "records") and options.len >= 8,
    };
}

/// The Filter menu's entries for the fields the view offers to filter by: a link adds the
/// field's pill under its first operator and opens its value.
pub fn adders(page: *const Page, items: *std.ArrayList(Adder)) Error!void {
    std.debug.assert(page.effective.clauses.len <= model.view.clauses_max);

    const offer = page.offer orelse return;
    const arena = page.session.arena;

    for (offer.filterable) |field| {
        const prefix = model.field_filter.prefix;
        const key = try std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, field.name });
        const added = page.effective.clause(key) != null;

        items.append(arena, .{
            .label = try page.session.declared(field.label),
            .href = if (added) "" else try add_href(page, field),
            .added = added,
        }) catch return error.OutOfMemory;
    }
}

/// The list with a new pill on the field, its value menu open.
pub fn add_href(page: *const Page, field: view_default.Filterable) Error![]const u8 {
    std.debug.assert(field.operators.len > 0);

    const arena = page.session.arena;
    const past_end: u32 = @intCast(page.effective.clauses.len);
    const clause: Clause = .{
        .key = try std.fmt.allocPrint(arena, "{s}{s}", .{ model.field_filter.prefix, field.name }),
        .operator = field.operators[0].id,
    };
    const address = try page.href(try model.view.with(arena, page.effective, past_end, clause));

    return std.fmt.allocPrint(arena, "{s}#filter-field-{s}", .{ address, field.name }) catch {
        return error.OutOfMemory;
    };
}

fn operators_of(
    page: *const Page,
    clause: Clause,
    index: u32,
    field: view_default.Filterable,
) Error![]const Operator {
    std.debug.assert(field.operators.len > 0);

    const arena = page.session.arena;
    const current = view_offer.operator_of(page.offer.?, field.name, clause.operator).?;
    const out = arena.alloc(Operator, field.operators.len) catch return error.OutOfMemory;

    for (field.operators, out) |operator, *item| {
        const same_value = std.mem.eql(u8, operator.takes, current.takes);
        const kept: Clause = .{
            .key = clause.key,
            .operator = operator.id,
            .value = if (same_value) clause.value else "",
        };

        item.* = .{
            .label = try page.session.declared(operator.label),
            .href = try page.href(try model.view.with(arena, page.effective, index, kept)),
            .selected = std.mem.eql(u8, operator.id, clause.operator),
        };
    }

    return out;
}

fn kind_of(takes: []const u8) []const u8 {
    std.debug.assert(takes.len > 0);

    const by = std.meta.stringToEnum(model.field_filter.Takes, takes) orelse return "none";

    return switch (by) {
        .text => "text",
        .number => "number",
        .day => "day",
        .number_range => "number_range",
        .day_range => "day_range",
        .span => "span",
        .choices, .yes_no, .records => "choice",
    };
}

fn single(takes: []const u8) bool {
    return std.mem.eql(u8, takes, "text") or std.mem.eql(u8, takes, "number") or
        std.mem.eql(u8, takes, "day");
}

const Parts = struct {
    low: []const u8 = "",
    high: []const u8 = "",
    count: []const u8 = "",
    unit: []const u8 = "d",
};

/// A range's two ends (`10..20`), a span's count and unit (`7d`).
fn parts_of(takes: []const u8, value: []const u8) Parts {
    std.debug.assert(value.len <= model.view.value_len_max);

    if (std.mem.endsWith(u8, takes, "_range")) {
        const dots = std.mem.indexOf(u8, value, "..") orelse return .{};

        return .{
            .low = value[0..dots],
            .high = value[dots + 2 ..],
        };
    }

    if (std.mem.eql(u8, takes, "span") and value.len >= 2) {
        return .{
            .count = value[0 .. value.len - 1],
            .unit = value[value.len - 1 ..],
        };
    }

    return .{};
}

/// What the pill says it holds: the value, the choices picked, a range or a span; "Any"
/// with nothing given yet.
fn value_text(
    page: *const Page,
    takes: []const u8,
    value: []const u8,
    options: []const Option,
) Error![]const u8 {
    std.debug.assert(value.len <= model.view.value_len_max);

    const session = page.session;
    const arena = session.arena;

    if (value.len == 0) {
        return if (std.mem.eql(u8, takes, "day"))
            session.translated("Pick a day", .{})
        else
            session.translated("Any", .{});
    }

    if (options.len > 0) {
        var picked: std.ArrayList([]const u8) = .empty;

        for (options) |option| {
            if (option.selected) {
                picked.append(arena, option.label) catch return error.OutOfMemory;
            }
        }

        return std.mem.join(arena, ", ", picked.items) catch return error.OutOfMemory;
    }

    const parts = parts_of(takes, value);

    if (parts.low.len > 0) {
        return std.fmt.allocPrint(arena, "{s} – {s}", .{ parts.low, parts.high }) catch {
            return error.OutOfMemory;
        };
    }

    if (parts.count.len > 0) {
        const count = count_of(parts.count);
        const unit = switch (parts.unit[0]) {
            'w' => try session.translated_count("{count} week", "{count} weeks", count),
            'm' => try session.translated_count("{count} month", "{count} months", count),
            'y' => try session.translated_count("{count} year", "{count} years", count),
            else => try session.translated_count("{count} day", "{count} days", count),
        };

        return unit;
    }

    return value;
}

fn count_of(text: []const u8) u32 {
    return std.fmt.parseInt(u32, text, 10) catch 0;
}

/// A choice menu's entries: a select's choices or yes/no, picked one or several at a time;
/// for a reference, the records it may point at.
fn options_of(
    page: *const Page,
    clause: Clause,
    index: u32,
    operator: view_default.Operator,
    def: ?model.field.Def,
) Error![]const Option {
    std.debug.assert(clause.key.len > 0);

    const arena = page.session.arena;
    var out: std.ArrayList(Option) = .empty;
    const chosen = try listed(arena, clause.value);

    if (std.mem.eql(u8, operator.takes, "yes_no")) {
        for ([_][2][]const u8{ .{ "yes", "Yes" }, .{ "no", "No" } }) |choice| {
            const picked: Clause = .{
                .key = clause.key,
                .operator = clause.operator,
                .value = choice[0],
            };

            out.append(arena, .{
                .label = try page.session.translated(choice[1], .{}),
                .href = try page.href(try model.view.with(arena, page.effective, index, picked)),
                .selected = std.mem.eql(u8, clause.value, choice[0]),
            }) catch return error.OutOfMemory;
        }

        return out.items;
    }

    const field = def orelse return out.items;

    if (std.mem.eql(u8, operator.takes, "choices")) {
        for (field.options.choices, 0..) |choice, position| {
            const label = if (position < field.options.labels.len)
                field.options.labels[position]
            else
                choice;

            try out.append(arena, try toggled(page, clause, index, chosen, choice, label));
        }
    } else if (std.mem.eql(u8, operator.takes, "records")) {
        const found = try targets_of(page, field);

        for (found) |record| {
            const option = try toggled(page, clause, index, chosen, record.id, record.title);
            try out.append(arena, option);
        }
    }

    return out.items;
}

/// One choice of several: picking it adds it to the list, picking it again takes it out.
fn toggled(
    page: *const Page,
    clause: Clause,
    index: u32,
    chosen: []const []const u8,
    id: []const u8,
    label: []const u8,
) Error!Option {
    std.debug.assert(id.len > 0);

    const arena = page.session.arena;
    const selected = contains(chosen, id);
    var next: std.ArrayList([]const u8) = .empty;

    for (chosen) |one| {
        if (!std.mem.eql(u8, one, id)) {
            next.append(arena, one) catch return error.OutOfMemory;
        }
    }

    if (!selected) {
        next.append(arena, id) catch return error.OutOfMemory;
    }

    const value = if (next.items.len == 0)
        ""
    else
        std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(next.items, .{})}) catch {
            return error.OutOfMemory;
        };
    const picked: Clause = .{
        .key = clause.key,
        .operator = clause.operator,
        .value = value,
    };

    return .{
        .label = label,
        .href = try page.href(try model.view.with(arena, page.effective, index, picked)),
        .selected = selected,
    };
}

/// The values a list clause holds: `["s","m"]`; none for an empty or unreadable one.
fn listed(arena: std.mem.Allocator, value: []const u8) Error![]const []const u8 {
    std.debug.assert(value.len <= model.view.value_len_max);

    if (value.len == 0 or value[0] != '[') {
        return &.{};
    }

    return std.json.parseFromSliceLeaky([]const []const u8, arena, value, .{}) catch &.{};
}

/// The records a reference field may point at, by title, the first few.
fn targets_of(page: *const Page, field: model.field.Def) Error![]const record_operations.Record {
    std.debug.assert(field.name.len > 0);

    if (field.options.to.len == 0) {
        return &.{};
    }

    var reading = page.session.*;
    const found = registry.SDK.dispatch(&reading.ctx, record_operations.List, .{
        .types = field.options.to,
        .order = .title_asc,
        .limit = records_offered_max,
    }) catch return &.{};

    return found.records;
}

/// The field's definition, read from its type.
fn field_def(page: *const Page, name: []const u8) Error!?model.field.Def {
    std.debug.assert(name.len > 0);

    if (page.effective.types.len != 1) {
        return null;
    }

    var reading = page.session.*;
    const got = registry.SDK.dispatch(&reading.ctx, types.Get, .{
        .type = page.effective.types[0],
    }) catch return null;
    const found = model.document.find_path(got.definition.fields, name) orelse return null;

    return found.*;
}

fn contains(names: []const []const u8, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) {
            return true;
        }
    }

    return false;
}
