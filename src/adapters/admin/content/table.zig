const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const model = @import("../../../model.zig");
const records = @import("../../../operations/record.zig");
const list = @import("list.zig");
const filters = @import("filters.zig");
const display = @import("../display.zig");
const section_columns = @import("section_columns.zig");

const Props = admin.views.ContentList.Props;
const Cell = admin.views.ContentList.CellsItem;
const Row = admin.views.ContentList.RowsItem;
const Column = admin.views.ContentList.ColumnsItem;
const Move = admin.views.ContentList.MovesItem;
const PageLink = admin.views.ContentList.PagesItem;
const Error = admin.Error;

pub fn fill(props: *Props, page: *const list.Page, found: []const records.Record) Error!void {
    std.debug.assert(found.len <= records.list_max);
    std.debug.assert(page.session.signed_in());

    const arena = page.session.arena;
    const titles = try display.titles(&page.session.ctx, found);
    const extra = try section_columns.of(page, found);
    var rows: std.ArrayList(Row) = .empty;

    for (found, titles, 0..) |record, title, position| {
        const own: []const []const u8 = if (extra) |columns| columns.cells[position] else &.{};

        try rows.append(arena, .{
            .id = record.id,
            .cells = try cells_of(page, record, title, props.show_type, own),
        });
    }

    props.rows = rows.items;
    const own_fields = if (extra) |columns| columns.fields else &.{};

    props.columns = try columns_of(page, props.show_type, own_fields);
    props.empty_text = if (page.effective.is_empty())
        try page.session.translated("No records yet. Create the first one.")
    else
        try page.session.translated("No records match these filters.");
}

/// What the selection's actions need: how many records match past the page, the
/// conditions that match them, and the statuses a transition leads to.
pub fn fill_selection(
    props: *Props,
    page: *const list.Page,
    list_in: records.List.In,
    total: u32,
) Error!void {
    std.debug.assert(page.session.signed_in());
    std.debug.assert(props.rows.len <= total or props.rows.len <= filters.page_size);

    const arena = page.session.arena;
    var moves: std.ArrayList(Move) = .empty;

    for (registry.Statuses.all) |status| {
        const action = action_to(status.id) orelse continue;

        try moves.append(arena, .{
            .to = status.id,
            .label = try page.session.declared(action),
            .status = try page.session.declared(status.label),
        });
    }

    props.total = @floatFromInt(total);
    props.moves = moves.items;
    props.match_type = list_in.type orelse "";
    props.match_types = list_in.types;
    props.match_filters = list_in.filters;
    props.match_search = list_in.search orelse "";
}

/// Pages of `filters.page_size` the matching records fill; one when there are none.
pub fn page_count(total: u32) u32 {
    std.debug.assert(filters.page_size > 0);

    const count = std.math.divCeil(u32, total, filters.page_size) catch unreachable;

    std.debug.assert(count <= total);

    return @max(count, 1);
}

/// Where the list stands among its pages: the address keeps the page, the links go to the
/// first, the last and the ones beside this one, a gap between.
pub fn fill_pages(props: *Props, page: *const list.Page, number: u32, total: u32) Error!void {
    std.debug.assert(number >= 1 and number <= page_count(total));
    std.debug.assert(props.rows.len <= filters.page_size);

    const session = page.session;
    const arena = session.arena;
    const base = props.address;
    const last = page_count(total);
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
    props.range_text = try range_of(session, number, @intCast(props.rows.len), total);
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

/// "21–40 of 10000": the rows shown among the matching ones.
fn range_of(session: *const admin.Session, number: u32, shown: u32, total: u32) Error![]const u8 {
    std.debug.assert(number >= 1);
    std.debug.assert(shown <= filters.page_size);

    const arena = session.arena;
    const first = (number - 1) * filters.page_size + @min(shown, 1);

    return session.translated_with("{first}–{last} of {total}", &.{
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
    });
}

/// The name of the first transition leading to a status: what moving there is called.
fn action_to(status: []const u8) ?[]const u8 {
    std.debug.assert(status.len > 0);
    std.debug.assert(registry.Statuses.all_transitions.len > 0);

    for (registry.Statuses.all_transitions) |transition| {
        if (std.mem.eql(u8, transition.to, status)) {
            return transition.label;
        }
    }

    return null;
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
    const status = registry.Statuses.find(record.status);
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
    workflow.extra = if (record.changed) try page.session.translated("changed") else "";
    workflow.extra_tone = "warning";
    try cells.append(arena, workflow);
    var updated = cell("updated", admin.time_text(arena, record.updated_at));
    updated.kind = "numeric";
    try cells.append(arena, updated);
    var open = cell("open", try page.session.translated("Open"));
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
    };
}

/// The ids of a section's own columns, after the title.
const own_ids = [_][]const u8{ "own_0", "own_1", "own_2", "own_3" };

fn columns_of(
    page: *const list.Page,
    show_type: bool,
    own: []const section_columns.Field,
) Error![]const Column {
    std.debug.assert(page.session.signed_in());
    std.debug.assert(page.effective.clauses.len <= model.view.clauses_max);

    const arena = page.session.arena;
    var title = page.effective;
    var updated = page.effective;
    title.order = "title_asc";
    updated.order = null;
    const order = filters.order_of(page.effective.order);
    var columns: std.ArrayList(Column) = .empty;
    try columns.append(arena, .{
        .id = "title",
        .label = try page.session.translated("Title"),
        .href = try page.href(title),
        .active = order == .title_asc,
    });

    for (own, 0..) |field, index| {
        try columns.append(arena, column(own_ids[index], field.label));
    }

    if (show_type) {
        try columns.append(arena, column("type", try page.session.translated("Content type")));
    }

    try columns.append(arena, column("slug", try page.session.translated("Slug")));
    try columns.append(arena, column("status", try page.session.translated("Status")));
    try columns.append(arena, .{
        .id = "updated",
        .label = try page.session.translated("Updated"),
        .href = try page.href(updated),
        .active = order == .updated_desc,
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
