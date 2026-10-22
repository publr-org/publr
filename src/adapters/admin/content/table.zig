const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const model = @import("../../../model.zig");
const records = @import("../../../operations/record.zig");
const list = @import("list.zig");
const filters = @import("filters.zig");
const display = @import("../display.zig");
const view_columns = @import("view_columns.zig");
const view_table = @import("view_table.zig");

const Props = admin.views.ContentList.Props;
const Cell = admin.views.ContentList.CellsItem;
const Row = admin.views.ContentList.RowsItem;
const Column = admin.views.ContentList.ColumnsItem;
const Transition = admin.views.ContentList.TransitionsItem;
const PageLink = admin.views.ContentList.PagesItem;
const Error = admin.Error;

pub fn fill(props: *Props, page: *const list.Page, found: []const records.Record) Error!void {
    std.debug.assert(found.len <= records.list_max);
    std.debug.assert(page.session.signed_in());

    const arena = page.session.arena;
    const titles = try display.titles(&page.session.ctx, found);
    const extra = try view_columns.of(page, found);
    var rows: std.ArrayList(Row) = .empty;

    const fields = if (extra) |columns| columns.fields else &.{};
    const lookups = try @import("cell_values.zig").gather(page, fields, if (extra) |columns|
        columns.values
    else
        &.{});

    for (found, titles, 0..) |record, title, position| {
        const values: []const std.json.Value = if (extra) |columns|
            columns.values[position]
        else
            &.{};

        try rows.append(arena, .{
            .id = record.id,
            .cells = try view_table.cells(page, record, title, .{
                .fields = fields,
                .values = values,
                .lookups = &lookups,
            }),
        });
    }

    props.rows = rows.items;
    props.columns = try view_table.columns(page, fields);
    props.empty_text = try empty_text(page);
}

fn empty_text(page: *const list.Page) Error![]const u8 {
    std.debug.assert(page.session.signed_in());

    return if (page.effective.clauses.len == 0 and page.effective.search == null)
        page.session.translated("No records yet. Create the first one.", .{})
    else
        page.session.translated("No records match these filters.", .{});
}

/// What the selection's actions need: how many records match past the page, the
/// conditions that match them, and the transitions they may make: the list's type's flow,
/// core's for a list of several, and the trash.
pub fn fill_selection(
    props: *Props,
    page: *const list.Page,
    list_in: records.List.In,
    total: u32,
) Error!void {
    std.debug.assert(page.session.signed_in());
    std.debug.assert(props.rows.len <= total or props.rows.len <= page.per_page());

    const arena = page.session.arena;
    var transitions: std.ArrayList(Transition) = .empty;
    const flow = try flow_of(page, list_in.type);

    for (flow.listed()) |transition| {
        if (named_already(transitions.items, transition.name)) {
            continue;
        }

        try transitions.append(arena, .{
            .name = transition.name,
            .label = try page.session.declared(transition.label),
            .status = try status_label(page, transition.to),
        });
    }

    try transitions.append(arena, .{
        .name = "trash",
        .label = try page.session.translated("Delete", .{}),
        .status = try status_label(page, model.flow.trashed),
    });

    props.total = @floatFromInt(total);
    props.transitions = transitions.items;
    props.match_type = list_in.type orelse "";
    props.match_types = list_in.types;
    props.match_filters = list_in.filters;
    props.match_search = list_in.search orelse "";
}

/// Pages of `per_page` the matching records fill; one when there are none.
pub fn page_count(total: u32, per_page: u32) u32 {
    std.debug.assert(per_page > 0);

    const count = std.math.divCeil(u32, total, per_page) catch unreachable;

    std.debug.assert(count <= total);

    return @max(count, 1);
}

/// Where the list stands among its pages: the address keeps the page, the links go to the
/// first, the last and the ones beside this one, a gap between.
pub fn fill_pages(props: *Props, page: *const list.Page, number: u32, total: u32) Error!void {
    std.debug.assert(number >= 1 and number <= page_count(total, page.per_page()));
    std.debug.assert(props.rows.len <= page.per_page());

    const session = page.session;
    const arena = session.arena;
    const base = props.address;
    const last = page_count(total, page.per_page());
    var links: std.ArrayList(PageLink) = .empty;
    var previous: u32 = 0;

    for (1..last + 1) |index| {
        const shown: u32 = @intCast(index);
        const near = shown + 1 >= number and shown <= number + 1;

        if (shown != 1 and shown != last and !near) {
            continue;
        }

        if (previous != 0 and shown > previous + 1) {
            try links.append(arena, .{
                .id = try std.fmt.allocPrint(arena, "gap-{d}", .{shown}),
                .label = "",
                .href = "",
                .current = false,
            });
        }

        try links.append(arena, .{
            .id = try std.fmt.allocPrint(arena, "page-{d}", .{shown}),
            .label = try std.fmt.allocPrint(arena, "{d}", .{shown}),
            .href = if (shown == number) "" else try address_of(arena, base, shown),
            .current = shown == number,
        });
        previous = shown;
    }

    props.address = try address_of(arena, base, number);
    props.pages = if (last > 1) links.items else &.{};
    props.previous_href = if (number > 1) try address_of(arena, base, number - 1) else "";
    props.next_href = if (number < last) try address_of(arena, base, number + 1) else "";
    props.range_text = try range_of(session, .{
        .number = number,
        .shown = @intCast(props.rows.len),
        .total = total,
        .per_page = page.per_page(),
    });
}

/// The list's address on a page: the first needs no `page`.
fn address_of(arena: std.mem.Allocator, base: []const u8, number: u32) Error![]const u8 {
    std.debug.assert(base.len > 0);
    std.debug.assert(number >= 1);

    if (number == 1) {
        return base;
    }

    const separator: u8 = if (std.mem.indexOfScalar(u8, base, '?') == null) '?' else '&';

    return std.fmt.allocPrint(arena, "{s}{c}page={d}", .{ base, separator, number });
}

const Range = struct {
    number: u32,
    shown: u32,
    total: u32,
    per_page: u32,
};

/// "21–40 of 10000": the rows shown among the matching ones.
fn range_of(session: *const admin.Session, range: Range) Error![]const u8 {
    std.debug.assert(range.number >= 1);
    std.debug.assert(range.shown <= range.per_page);

    const arena = session.arena;
    const shown = range.shown;
    const total = range.total;
    const first = (range.number - 1) * range.per_page + @min(shown, 1);

    return session.translated(
        "{first}–{last} of {total}",
        .{
            .values = &.{
                .{
                    .name = "first",
                    .value = try std.fmt.allocPrint(arena, "{d}", .{first}),
                },
                .{
                    .name = "last",
                    .value = try std.fmt.allocPrint(arena, "{d}", .{first + shown -| 1}),
                },
                .{
                    .name = "total",
                    .value = try std.fmt.allocPrint(arena, "{d}", .{total}),
                },
            },
        },
    );
}

/// The flow a list's records move by: its type's, or core's for a list of several types.
fn flow_of(page: *const list.Page, handle: ?[]const u8) Error!model.flow.Flow {
    std.debug.assert(page.session.signed_in());

    const named = handle orelse return model.flow.core;
    const ctx = &page.session.ctx;
    // A type that cannot be read now offers core's transitions; the server checks each.
    const found = records.domain.definition.find(ctx, named) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return model.flow.core,
    };
    const type_row = found orelse return model.flow.core;

    std.debug.assert(type_row.def.handle.len > 0);

    return type_row.def.flow;
}

fn named_already(transitions: []const Transition, name: []const u8) bool {
    std.debug.assert(name.len > 0);
    std.debug.assert(transitions.len <= model.flow.transitions_max + 1);

    for (transitions) |transition| {
        if (std.mem.eql(u8, transition.name, name)) {
            return true;
        }
    }

    return false;
}

/// A status as people read it, by its id.
fn status_label(page: *const list.Page, id: []const u8) Error![]const u8 {
    std.debug.assert(id.len > 0);

    const status = @import("../../../operations/status.zig").find_in(page.statuses, id);
    const label = if (status) |found| found.label else id;

    return page.session.declared(label);
}

fn cells_of(
    page: *const list.Page,
    record: records.Record,
    shown_title: []const u8,
    show_type: bool,
    own: []const []const u8,
) Error![]const Cell {
    std.debug.assert(record.id.len > 0);
    std.debug.assert(page.session.signed_in());

    const arena = page.session.arena;
    const href = try std.fmt.allocPrint(arena, "/admin/content/{s}", .{record.id});
    const type_name = if (page.type_named(record.type)) |found| found.name else record.type;
    const status = @import("../../../operations/status.zig").find_in(page.statuses, record.status);
    var cells: std.ArrayList(Cell) = .empty;
    var title = cell("title", shown_title);
    title.href = href;
    try cells.append(arena, title);

    for (own, 0..) |text, index| {
        try cells.append(arena, cell(own_ids[index], text));
    }

    if (show_type) {
        try cells.append(arena, cell("type", type_name));
    }

    var slug = cell("slug", record.slug orelse "");
    slug.kind = "mono";
    try cells.append(arena, slug);
    var workflow = cell("status", record.status);
    workflow.kind = "status";
    workflow.tone = tone_of(if (status) |found| found.color else .neutral);
    workflow.extra = if (record.changed) try page.session.translated("changed", .{}) else "";
    workflow.extra_tone = "warning";
    try cells.append(arena, workflow);
    var updated = cell("updated", admin.time_text(arena, record.updated_at));
    updated.kind = "numeric";
    try cells.append(arena, updated);
    var open = cell("open", try page.session.translated("Open", .{}));
    open.kind = "action";
    open.href = href;
    try cells.append(arena, open);

    return cells.items;
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

/// The ids of the type's own columns, after the title.
const own_ids = [_][]const u8{ "own_0", "own_1", "own_2", "own_3" };

fn columns_of(
    page: *const list.Page,
    show_type: bool,
    own: []const view_columns.Field,
) Error![]const Column {
    std.debug.assert(page.session.signed_in());
    std.debug.assert(page.effective.clauses.len <= model.view.clauses_max);

    const arena = page.session.arena;
    var title = page.effective;
    var updated = page.effective;
    title.order = "title";
    updated.order = null;
    const order = filters.order_of(page.effective.order);
    var columns: std.ArrayList(Column) = .empty;
    try columns.append(arena, .{
        .id = "title",
        .label = try page.session.translated("Title", .{}),
        .href = try page.href(title),
        .active = order == .title_asc,
        .sort = if (order == .title_asc) "asc" else "",
        .@"align" = "",
        .menu = &.{},
    });

    for (own, 0..) |field, index| {
        try columns.append(arena, column(own_ids[index], field.label));
    }

    if (show_type) {
        try columns.append(arena, column("type", try page.session.translated("Content type", .{})));
    }

    try columns.append(arena, column("slug", try page.session.translated("Slug", .{})));
    try columns.append(arena, column("status", try page.session.translated("Status", .{})));
    try columns.append(arena, .{
        .id = "updated",
        .label = try page.session.translated("Updated", .{}),
        .href = try page.href(updated),
        .active = order == .updated_desc,
        .sort = if (order == .updated_desc) "desc" else "",
        .@"align" = "",
        .menu = &.{},
    });
    try columns.append(arena, column("open", ""));

    return columns.items;
}

fn column(id: []const u8, label: []const u8) Column {
    std.debug.assert(id.len > 0);

    return .{
        .id = id,
        .label = label,
        .href = "",
        .active = false,
        .sort = "",
        .@"align" = "",
        .menu = &.{},
    };
}

fn tone_of(color: model.status.Color) []const u8 {
    std.debug.assert(@typeInfo(model.status.Color).@"enum".fields.len == 5);

    return switch (color) {
        .neutral => "neutral",
        .info => "accent",
        .success => "success",
        .warning => "warning",
        .danger => "error",
    };
}

pub fn answer(session: *admin.Session, props: Props) Error!void {
    std.debug.assert(session.signed_in());
    std.debug.assert(props.address.len > 0);

    return session.response.json(.ok, .{
        .data = .{
            .address = props.address,
            .columns = props.columns,
            .rows = props.rows,
            .filters = props.filters,
            .hidden = props.hidden,
            .search = props.search,
            .add_filters = props.add_filters,
            .empty_text = props.empty_text,
            .total = props.total,
            .pages = props.pages,
            .previous_href = props.previous_href,
            .next_href = props.next_href,
            .range_text = props.range_text,
            .sort_options = props.sort_options,
            .direction_options = props.direction_options,
            .page_size_options = props.page_size_options,
            .properties = props.properties,
        },
        .context = .{
            .title = props.title,
            .shown_text = props.shown_text,
            .is_saved = props.is_saved,
            .view_changed = props.view_changed,
            .base_href = props.base_href,
            .filters_query = props.filters_query,
            .copy_name = props.copy_name,
            .save_href = props.save_href,
            .delete_href = props.delete_href,
            .rename_href = props.rename_href,
            .default_type = props.default_type,
            .own_default = props.own_default,
            .everyone_default = props.everyone_default,
            .is_admin = props.is_admin,
            .view_shared = props.view_shared,
            .new_href = props.new_href,
            .new_label = props.new_label,
            .new_targets = props.new_targets,
            .conditions = .{
                .type = props.match_type,
                .types = props.match_types,
                .filters = props.match_filters,
                .search = props.match_search,
            },
        },
    });
}
