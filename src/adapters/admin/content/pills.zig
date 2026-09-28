//! The filter bar of the content list: the type pill, one pill per clause in force in the
//! order they were added, drawn from the filter registry (its label, its operators, what
//! each operator takes), the menu that adds one, and the hidden fields that carry them
//! all under the search box.
const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const model = @import("../../../model.zig");
const users = @import("../../../operations/user.zig");
const filters = @import("filters.zig");
const list = @import("list.zig");

const Error = admin.Error;
const views = admin.views;
const Filters = model.view.Filters;
const Clause = model.filter.Clause;
const Definition = model.filter.Definition;
const Page = list.Page;
const Pill = views.ContentList.FiltersItem;
const Option = views.ContentList.OptionsItem;
const Operator = views.ContentList.OperatorsItem;
const Hidden = views.ContentList.HiddenItem;
const Carried = views.ContentList.CarriedItem;

const type_search_from: u32 = 8;

pub fn fill(props: *views.ContentList.Props, page: *const Page) Error!void {
    std.debug.assert(page.types.len <= 4096);
    std.debug.assert(page.effective.clauses.len <= model.view.clauses_max);

    const arena = page.session.arena;
    var rows: std.ArrayList(Pill) = .empty;

    if (props.show_type) {
        try rows.append(arena, try type_pill(page));
    }

    for (page.effective.clauses, 0..) |clause, index| {
        const def = registry.Filters.find(clause.key) orelse continue;

        const at: u32 = @intCast(index);

        rows.append(arena, try pill_of(page, def, clause, at)) catch return error.OutOfMemory;
    }

    props.filters = rows.items;
    props.add_filters = try adders(page);
    props.hidden = try pairs_of(Hidden, page, page.effective);
}

/// The type pill: every record type, ticked when in the list; a search past a few.
fn type_pill(page: *const Page) Error!Pill {
    std.debug.assert(page.types.len <= 4096);
    std.debug.assert(page.effective.types.len <= model.view.types_max);

    const arena = page.session.arena;
    const chosen = page.effective.types;
    var options: std.ArrayList(Option) = .empty;

    for (page.types) |summary| {
        if (summary.kind != .record) {
            continue;
        }

        const checked = list.contains(chosen, summary.handle);
        var toggled = page.effective;
        toggled.types = try toggle(arena, chosen, summary.handle, !checked);

        options.append(arena, .{
            .label = summary.name,
            .href = try page.href(toggled),
            .selected = checked,
        }) catch return error.OutOfMemory;
    }

    var cleared = page.effective;
    cleared.types = &.{};

    const label = if (chosen.len == 0)
        "Any"
    else if (chosen.len == 1)
        (if (page.type_named(chosen[0])) |found| found.name else chosen[0])
    else
        try std.fmt.allocPrint(arena, "{d} types", .{chosen.len});

    return .{
        .id = "filter-type",
        .name = "types",
        .label = "Content type",
        .operator = "is",
        .operator_id = "is",
        .operator_name = "types_operator",
        .operators = &.{.{ .label = "is", .href = "", .selected = true }},
        .value = label,
        .value_kind = "choice",
        .day = "",
        .options = options.items,
        .carried = &.{},
        .remove_href = "",
        .reset_href = try page.href(cleared),
        .searchable = options.items.len >= type_search_from,
    };
}

fn toggle(
    arena: std.mem.Allocator,
    chosen: []const []const u8,
    handle: []const u8,
    add: bool,
) Error![]const []const u8 {
    std.debug.assert(handle.len > 0);
    std.debug.assert(chosen.len <= model.view.types_max);

    var out: std.ArrayList([]const u8) = .empty;

    for (chosen) |candidate| {
        if (!std.mem.eql(u8, candidate, handle)) {
            out.append(arena, candidate) catch return error.OutOfMemory;
        }
    }

    if (add and out.items.len < model.view.types_max) {
        out.append(arena, handle) catch return error.OutOfMemory;
    }

    return out.items;
}

/// One pill: the filter's label, its operator (a menu of them when it has more than
/// one), its value (a menu of choices, or a day to pick), and the way out. The pill is
/// the clause at `index`; a filter may have several, one per thing its operators settle.
fn pill_of(page: *const Page, def: Definition, clause: Clause, index: u32) Error!Pill {
    std.debug.assert(def.operators.len > 0);
    std.debug.assert(std.mem.eql(u8, def.key, clause.key));

    const arena = page.session.arena;
    const operator = def.operator(clause.operator) orelse def.operators[0];
    const choices = try choices_of(page, def, operator);
    var options: std.ArrayList(Option) = .empty;
    var value: []const u8 = if (operator.takes == .day) "Pick a day" else "Any";

    for (choices) |choice| {
        const selected = std.mem.eql(u8, choice.id, clause.value);
        const chosen: Clause = .{ .key = def.key, .operator = operator.id, .value = choice.id };

        if (selected) {
            value = choice.label;
        }

        options.append(arena, .{
            .label = choice.label,
            .href = try page.href(try model.view.with(arena, page.effective, index, chosen)),
            .selected = selected,
        }) catch return error.OutOfMemory;
    }

    if (operator.takes == .day and clause.value.len > 0) {
        value = clause.value;
    }

    const rest = try model.view.without(arena, page.effective, index);

    return .{
        .id = try std.fmt.allocPrint(arena, "filter-{s}-{s}", .{ def.key, operator.slot }),
        .name = def.key,
        .label = def.label,
        .operator = operator.label,
        .operator_id = operator.id,
        .operator_name = try std.fmt.allocPrint(arena, "{s}_operator", .{def.key}),
        .operators = try operators_of(page, def, clause, index),
        .value = value,
        .value_kind = switch (operator.takes) {
            .choice, .duration => "choice",
            .day => "day",
            .nothing => "none",
        },
        .day = if (operator.takes == .day) clause.value else "",
        .options = options.items,
        .carried = try pairs_of(Carried, page, rest),
        .remove_href = try page.href(rest),
        .reset_href = "",
        .searchable = false,
    };
}

/// What the operator's value menu offers: "any" and the source's choices, or the
/// durations; a day is picked, not chosen.
fn choices_of(
    page: *const Page,
    def: Definition,
    operator: model.filter.Operator,
) Error![]const model.filter.Choice {
    std.debug.assert(def.key.len > 0);
    std.debug.assert(page.session.signed_in());

    const arena = page.session.arena;
    var out: std.ArrayList(model.filter.Choice) = .empty;

    switch (operator.takes) {
        .day, .nothing => return out.items,
        .duration => {
            out.appendSlice(arena, &model.filter.durations) catch return error.OutOfMemory;

            return out.items;
        },
        .choice => {},
    }

    out.append(arena, .{ .id = "", .label = "Any" }) catch return error.OutOfMemory;

    switch (def.source) {
        .none => {},
        .changes => out.appendSlice(arena, &model.filter.changes) catch return error.OutOfMemory,
        .statuses => {
            for (registry.Statuses.all) |status| {
                out.append(arena, .{ .id = status.id, .label = status.label }) catch {
                    return error.OutOfMemory;
                };
            }
        },
        .users => try append_users(page, &out),
    }

    return out.items;
}

/// Me, and, for an admin, every other user by name.
fn append_users(page: *const Page, out: *std.ArrayList(model.filter.Choice)) Error!void {
    std.debug.assert(page.session.signed_in());
    std.debug.assert(out.items.len <= 1);

    const arena = page.session.arena;

    out.append(arena, model.filter.me) catch return error.OutOfMemory;

    const nobody: users.List.Out = .{ .users = &.{} };
    const everyone = registry.SDK.dispatch(&page.session.ctx, users.List, .{}) catch |err| blk: {
        if (err != error.Denied) {
            return error.OutOfMemory;
        }

        break :blk nobody;
    };

    for (everyone.users) |account| {
        if (std.mem.eql(u8, account.id, page.user_id())) {
            continue;
        }

        out.append(arena, .{ .id = account.id, .label = account.display_name }) catch {
            return error.OutOfMemory;
        };
    }
}

/// The filter's operators this clause may take: its own, and the ones settling something
/// no other clause of the filter settles; each keeps the value when it takes it.
fn operators_of(
    page: *const Page,
    def: Definition,
    clause: Clause,
    index: u32,
) Error![]const Operator {
    std.debug.assert(def.operators.len > 0);
    std.debug.assert(clause.key.len > 0);

    const arena = page.session.arena;
    var out: std.ArrayList(Operator) = .empty;

    for (def.operators) |operator| {
        const kept: Clause = .{
            .key = def.key,
            .operator = operator.id,
            .value = if (model.filter.fits(operator, clause.value)) clause.value else "",
        };

        if (taken(page.effective, kept, index)) {
            continue;
        }

        out.append(arena, .{
            .label = operator.label,
            .href = try page.href(try model.view.with(arena, page.effective, index, kept)),
            .selected = std.mem.eql(u8, operator.id, clause.operator),
        }) catch return error.OutOfMemory;
    }

    return out.items;
}

/// Whether a clause other than the one at `index` already settles what `clause` would.
fn taken(effective: Filters, clause: Clause, index: u32) bool {
    std.debug.assert(clause.key.len > 0);
    std.debug.assert(effective.clauses.len <= model.view.clauses_max);

    for (effective.clauses, 0..) |other, position| {
        if (position != index and registry.Filters.clash(other, clause)) {
            return true;
        }
    }

    return false;
}

/// The Filter menu: every filter the registry knows; greyed once every thing its
/// operators settle is settled. A link adds the filter under the first operator still
/// free (its default value when that operator takes it) and lands on the new pill, whose
/// value menu the band opens at once.
fn adders(page: *const Page) Error![]const views.ContentList.Add_filtersItem {
    std.debug.assert(page.effective.clauses.len <= model.view.clauses_max);
    std.debug.assert(registry.Filters.all.len > 0);

    const arena = page.session.arena;
    const past_end: u32 = @intCast(page.effective.clauses.len);
    var items: std.ArrayList(views.ContentList.Add_filtersItem) = .empty;

    for (registry.Filters.all) |def| {
        var fresh: ?Clause = null;

        for (def.operators) |operator| {
            const takes_default = model.filter.fits(operator, def.default_value);
            const value = if (takes_default) def.default_value else "";
            const candidate: Clause = .{ .key = def.key, .operator = operator.id, .value = value };

            if (!taken(page.effective, candidate, past_end)) {
                fresh = candidate;
                break;
            }
        }

        const clause = fresh orelse {
            items.append(arena, .{ .label = def.label, .href = "", .added = true }) catch {
                return error.OutOfMemory;
            };

            continue;
        };
        const address = try page.href(try model.view.with(arena, page.effective, past_end, clause));
        const slot = def.operator(clause.operator).?.slot;
        const parts = .{ address, def.key, slot };
        const href = std.fmt.allocPrint(arena, "{s}#filter-{s}-{s}", parts) catch {
            return error.OutOfMemory;
        };

        items.append(arena, .{ .label = def.label, .href = href, .added = false }) catch {
            return error.OutOfMemory;
        };
    }

    return items.items;
}

/// Everything an address carries but the search, as a form's hidden fields: the whole
/// list's, or the list without the clause a form of its own supplies.
fn pairs_of(comptime Item: type, page: *const Page, of: Filters) Error![]const Item {
    std.debug.assert(page.query.len <= filters.query_len_max);
    std.debug.assert(of.clauses.len <= model.view.clauses_max);

    const arena = page.session.arena;
    const address = try page.href(of);
    const question = std.mem.indexOfScalar(u8, address, '?') orelse return &.{};
    var items: std.ArrayList(Item) = .empty;
    var pairs = std.mem.splitScalar(u8, address[question + 1 ..], '&');

    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const name = pair[0..equals];

        if (std.mem.eql(u8, name, "q")) {
            continue;
        }

        items.append(arena, .{
            .id = pair,
            .name = name,
            .value = filters.decode(arena, pair[equals + 1 ..]) orelse "",
        }) catch return error.OutOfMemory;
    }

    return items.items;
}
