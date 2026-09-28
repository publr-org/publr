const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../app/registry.zig");
const model = @import("../../../model.zig");
const records = @import("../../../operations/record.zig");
const list = @import("list.zig");
const filters = @import("filters.zig");

const Props = admin.views.ContentList.Props;
const Cell = admin.views.ContentList.CellsItem;
const Row = admin.views.ContentList.RowsItem;
const Column = admin.views.ContentList.ColumnsItem;
const Error = admin.Error;

pub fn fill(props: *Props, page: *const list.Page, found: []const records.Record) Error!void {
    std.debug.assert(found.len <= records.list_max);
    std.debug.assert(page.session.signed_in());

    const arena = page.session.arena;
    var rows: std.ArrayList(Row) = .empty;

    for (found) |record| {
        try rows.append(arena, .{
            .id = record.id,
            .cells = try cells_of(page, record, props.show_type),
        });
    }

    props.rows = rows.items;
    props.columns = try columns_of(page, props.show_type);
    props.empty_text = if (page.effective.is_empty())
        "No records yet. Create the first one."
    else
        "No records match these filters.";
}

fn cells_of(page: *const list.Page, record: records.Record, show_type: bool) Error![]const Cell {
    std.debug.assert(record.id.len > 0);
    std.debug.assert(page.session.signed_in());

    const arena = page.session.arena;
    const href = try std.fmt.allocPrint(arena, "/admin/content/{s}", .{record.id});
    const type_name = if (page.type_named(record.type)) |found| found.name else record.type;
    const status = registry.Statuses.find(record.status);
    var cells: std.ArrayList(Cell) = .empty;
    var title = cell("title", if (record.title.len > 0) record.title else record.id);
    title.href = href;
    try cells.append(arena, title);

    if (show_type) {
        try cells.append(arena, cell("type", type_name));
    }

    var slug = cell("slug", record.slug orelse "");
    slug.kind = "mono";
    try cells.append(arena, slug);
    var workflow = cell("status", record.status);
    workflow.kind = "status";
    workflow.tone = tone_of(if (status) |found| found.color else .neutral);
    workflow.extra = if (record.changed) "changed" else "";
    workflow.extra_tone = "warning";
    try cells.append(arena, workflow);
    var updated = cell("updated", admin.time_text(arena, record.updated_at));
    updated.kind = "numeric";
    try cells.append(arena, updated);
    var open = cell("open", "Open");
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

fn columns_of(page: *const list.Page, show_type: bool) Error![]const Column {
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
        .label = "Title",
        .href = try page.href(title),
        .active = order == .title_asc,
    });

    if (show_type) {
        try columns.append(arena, column("type", "Content type"));
    }

    try columns.append(arena, column("slug", "Slug"));
    try columns.append(arena, column("status", "Status"));
    try columns.append(arena, .{
        .id = "updated",
        .label = "Updated",
        .href = try page.href(updated),
        .active = order == .updated_desc,
    });
    try columns.append(arena, column("open", ""));

    return columns.items;
}

fn column(id: []const u8, label: []const u8) Column {
    std.debug.assert(id.len > 0);

    return .{ .id = id, .label = label, .href = "", .active = false };
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
        },
    });
}
