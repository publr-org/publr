//! A one-type list's columns as its view lists them: the title first, then each column in
//! the view's order (a field of the type, or core's slug, status, updated, created), then
//! the way into a record. Each header's menu sorts by it either way, hides it, moves it and
//! filters by it, as far as the type offers.
const std = @import("std");
const admin = @import("../../admin.zig");
const model = @import("../../../model.zig");
const records = @import("../../../operations/record.zig");
const status_operations = @import("../../../operations/status.zig");
const list = @import("list.zig");
const field_pills = @import("field_pills.zig");
const view_columns = @import("view_columns.zig");
const view_offer = @import("view_offer.zig");
const cell_values = @import("cell_values.zig");

const Error = admin.Error;
const Column = admin.views.ContentList.ColumnsItem;
const MenuItem = admin.views.ContentList.MenuItem;
const Cell = admin.views.ContentList.CellsItem;
const Filters = model.view.Filters;
const Page = list.Page;

/// The kinds a column aligns to the end: amounts.
const amounts = [_][]const u8{ "integer", "number", "money" };

pub fn columns(page: *const Page, fields: []const view_columns.Field) Error![]const Column {
    std.debug.assert(page.offer != null);

    const session = page.session;
    const arena = session.arena;
    const names = page.columns();
    var out: std.ArrayList(Column) = .empty;

    out.append(arena, try header(page, "title", try session.translated("Title", .{}), "", .{
        .hide = false,
    })) catch return error.OutOfMemory;

    for (names, 0..) |name, position| {
        const field = field_named(fields, name);
        const label = if (field) |found| found.label else try core_label(session, name);
        const kind = if (field) |found| found.kind else "";

        out.append(arena, try header(page, name, label, kind, .{
            .position = @intCast(position),
        })) catch return error.OutOfMemory;
    }

    out.append(arena, .{
        .id = "open",
        .label = "",
        .href = "",
        .active = false,
        .sort = "",
        .@"align" = "",
        .menu = &.{},
    }) catch return error.OutOfMemory;

    return out.items;
}

const Placed = struct {
    hide: bool = true,
    position: u32 = 0,
};

/// A column's header: its sort state and menu.
fn header(
    page: *const Page,
    name: []const u8,
    label: []const u8,
    kind: []const u8,
    placed: Placed,
) Error!Column {
    std.debug.assert(name.len > 0);

    const session = page.session;
    const arena = session.arena;
    const order = (page.effective.order orelse "-updated");
    const descending = std.mem.startsWith(u8, order, "-");
    const current = std.mem.eql(u8, if (descending) order[1..] else order, name);
    const sortable = orderable(page, name);
    var menu: std.ArrayList(MenuItem) = .empty;

    if (sortable) {
        const up = try session.translated("Sort ascending", .{});
        try item(&menu, arena, "asc", up, "arrow-up", try ordered(page, name, false));
        const down = try session.translated("Sort descending", .{});
        try item(&menu, arena, "desc", down, "arrow-down", try ordered(page, name, true));
    }

    if (placed.hide) {
        const names = page.columns();

        if (placed.position > 0) {
            const left = try moved(page, placed.position, placed.position - 1);
            try item(&menu, arena, "left", try session.translated(
                "Move left",
                .{},
            ), "arrow-left", left);
        }

        if (placed.position + 1 < names.len) {
            const right = try moved(page, placed.position, placed.position + 1);
            const right_label = try session.translated("Move right", .{});
            try item(&menu, arena, "right", right_label, "arrow-right", right);
        }

        const hidden = try page.href(try without_column(page, name));
        try item(&menu, arena, "hide", try session.translated("Hide", .{}), "eye-off", hidden);
    }

    if (filter_href(page, name)) |href| {
        const filter_label = try session.translated("Filter by", .{});
        try item(&menu, arena, "filter", filter_label, "filter-lines", try href);
    }

    return .{
        .id = name,
        .label = label,
        .href = if (sortable) try ordered(page, name, current and !descending) else "",
        .active = current,
        .sort = if (!current) "" else if (descending) "desc" else "asc",
        .@"align" = if (listed(&amounts, kind)) "end" else "",
        .menu = menu.items,
    };
}

fn item(
    menu: *std.ArrayList(MenuItem),
    arena: std.mem.Allocator,
    id: []const u8,
    label: []const u8,
    icon: []const u8,
    href: []const u8,
) Error!void {
    std.debug.assert(id.len > 0);

    menu.append(arena, .{
        .id = id,
        .label = label,
        .icon = icon,
        .href = href,
    }) catch return error.OutOfMemory;
}

/// Whether the view offers to order by it.
fn orderable(page: *const Page, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    const offer = page.offer orelse return false;

    return view_offer.find_named(offer.orderable, name) != null;
}

fn ordered(page: *const Page, name: []const u8, descending: bool) Error![]const u8 {
    std.debug.assert(name.len > 0);

    var changed = page.effective;
    changed.order = if (descending)
        std.fmt.allocPrint(page.session.arena, "-{s}", .{name}) catch return error.OutOfMemory
    else
        name;

    return page.href(changed);
}

fn moved(page: *const Page, from: u32, to: u32) Error![]const u8 {
    const arena = page.session.arena;
    const names = arena.dupe([]const u8, page.columns()) catch return error.OutOfMemory;

    std.debug.assert(from < names.len and to < names.len);

    std.mem.swap([]const u8, &names[from], &names[to]);

    var changed = page.effective;
    changed.columns = names;

    return page.href(changed);
}

pub fn without_column(page: *const Page, name: []const u8) Error!Filters {
    std.debug.assert(name.len > 0);

    const arena = page.session.arena;
    var names: std.ArrayList([]const u8) = .empty;

    for (page.columns()) |candidate| {
        if (!std.mem.eql(u8, candidate, name)) {
            names.append(arena, candidate) catch return error.OutOfMemory;
        }
    }

    var changed = page.effective;
    changed.columns = names.items;

    return changed;
}

/// A new pill on the field, when the view offers to filter by it and has none on it yet.
fn filter_href(page: *const Page, name: []const u8) ?Error![]const u8 {
    std.debug.assert(name.len > 0);

    const offer = page.offer orelse return null;
    const field = view_offer.filterable(offer, name) orelse return null;
    const prefix = model.field_filter.prefix;
    const key = std.fmt.allocPrint(page.session.arena, "{s}{s}", .{ prefix, name }) catch {
        return error.OutOfMemory;
    };

    if (page.effective.clause(key) != null) {
        return null;
    }

    return field_pills.add_href(page, field);
}

pub const Values = struct {
    fields: []const view_columns.Field,
    /// The record's value of each field, in `fields`' order.
    values: []const std.json.Value,
    lookups: *const cell_values.Lookups,
};

/// A record's row: its title, then each column in the view's order, then the way in.
pub fn cells(
    page: *const Page,
    record: records.Record,
    title: []const u8,
    given: Values,
) Error![]const Cell {
    std.debug.assert(record.id.len > 0);
    std.debug.assert(given.fields.len == given.values.len or given.values.len == 0);

    const session = page.session;
    const arena = session.arena;
    const href = try std.fmt.allocPrint(arena, "/admin/content/{s}", .{record.id});
    var out: std.ArrayList(Cell) = .empty;
    var first = cell("title", title);

    first.href = href;
    out.append(arena, first) catch return error.OutOfMemory;

    for (page.columns()) |name| {
        out.append(arena, try cell_of(page, record, name, given)) catch {
            return error.OutOfMemory;
        };
    }

    var open = cell("open", try session.translated("Open", .{}));

    open.kind = "action";
    open.href = href;
    out.append(arena, open) catch return error.OutOfMemory;

    return out.items;
}

fn cell_of(
    page: *const Page,
    record: records.Record,
    name: []const u8,
    given: Values,
) Error!Cell {
    std.debug.assert(name.len > 0);

    for (given.fields, 0..) |field, position| {
        if (std.mem.eql(u8, field.name, name)) {
            const value = if (position < given.values.len) given.values[position] else .null;

            return cell_values.cell(page, given.lookups, field, value);
        }
    }

    const session = page.session;
    const arena = session.arena;

    if (std.mem.eql(u8, name, "type")) {
        return cell(name, if (page.type_named(record.type)) |found| found.name else record.type);
    }

    if (std.mem.eql(u8, name, "slug")) {
        var slug = cell(name, record.slug orelse "");

        slug.kind = "mono";

        return slug;
    }

    if (std.mem.eql(u8, name, "status")) {
        const status = status_operations.find_in(page.statuses, record.status);
        const shown = if (status) |found| try session.declared(found.label) else record.status;
        var workflow = cell(name, shown);

        workflow.kind = "status";
        workflow.tone = tone_of(if (status) |found| found.color else .neutral);
        workflow.extra = if (record.changed) try session.translated("changed", .{}) else "";
        workflow.extra_tone = "warning";

        return workflow;
    }

    const created = std.mem.eql(u8, name, "created");

    if (!created and !std.mem.eql(u8, name, "updated")) {
        return cell(name, "");
    }

    const at = if (created) record.created_at else record.updated_at;
    var moment = cell(name, admin.time_text(arena, at));

    moment.kind = "numeric";

    return moment;
}

fn cell(id: []const u8, text: []const u8) Cell {
    std.debug.assert(id.len > 0);

    return .{
        .id = id,
        .text = text,
        .href = "",
        .kind = "text",
        .tone = "neutral",
        .extra = "",
        .extra_tone = "neutral",
        .items = &.{},
    };
}

pub fn tone_of(color: model.status.Color) []const u8 {
    std.debug.assert(@typeInfo(model.status.Color).@"enum".fields.len == 5);

    return switch (color) {
        .neutral => "neutral",
        .info => "accent",
        .success => "success",
        .warning => "warning",
        .danger => "error",
    };
}

pub fn core_label(session: *const admin.Session, name: []const u8) Error![]const u8 {
    std.debug.assert(name.len > 0);

    const labels = [_][2][]const u8{
        .{ "title", "Title" },
        .{ "type", "Content type" },
        .{ "slug", "Slug" },
        .{ "status", "Status" },
        .{ "updated", "Updated" },
        .{ "created", "Created" },
    };

    for (labels) |pair| {
        if (std.mem.eql(u8, pair[0], name)) {
            return session.translated(pair[1], .{});
        }
    }

    return name;
}

fn field_named(fields: []const view_columns.Field, name: []const u8) ?view_columns.Field {
    std.debug.assert(name.len > 0);

    for (fields) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            return field;
        }
    }

    return null;
}

fn listed(names: []const []const u8, name: []const u8) bool {
    std.debug.assert(names.len > 0);

    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) {
            return true;
        }
    }

    return false;
}
