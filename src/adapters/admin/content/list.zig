//! The content list: the records the caller may read, under the filters the address or a
//! saved view names, with the filter bar and the view menu around them.
const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const model = @import("../../../model.zig");
const statuses = @import("../../../operations/status.zig");
const types = @import("../../../operations/content_type.zig");
const record_operations = @import("../../../operations/record.zig");
const saved_views = @import("../../../operations/view.zig");
const filters = @import("filters.zig");
const pills = @import("pills.zig");
const table = @import("table.zig");
const view_offer = @import("view_offer.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const Session = admin.Session;
const views = admin.views;
const Filters = model.view.Filters;
const Summary = types.Summary;

pub const back = "/admin/content";

/// Where the page stands, shared with the pill builders.
pub const Page = struct {
    session: *Session,
    query: []const u8,
    view_id: ?[]const u8,
    saved: ?saved_views.Saved,
    effective: Filters,
    changed: bool,
    types: []const Summary,
    /// Every status the site knows: core's and each type's own.
    statuses: []const model.status.Status,
    /// What a list of one type offers, and the default view it starts at.
    offer: ?view_offer.Offer = null,
    /// The view the list rests on: a saved view as saved, a type's default view, a built-in
    /// view; what Clear changes goes back to.
    resting: Filters = .{},
    default_columns: []const []const u8 = &.{},

    /// The columns shown: the view's, or the ones a view saying none shows.
    pub fn columns(page: *const Page) []const []const u8 {
        std.debug.assert(page.query.len <= filters.query_len_max);

        return page.effective.columns orelse page.default_columns;
    }

    pub fn per_page(page: *const Page) u32 {
        std.debug.assert(page.query.len <= filters.query_len_max);

        return page.effective.per_page orelse filters.page_size;
    }

    /// The list with these filters instead, the view kept.
    pub fn href(page: *const Page, modified: Filters) Error![]const u8 {
        std.debug.assert(page.query.len <= filters.query_len_max);
        std.debug.assert(modified.clauses.len <= model.view.clauses_max);

        return filters.format(page.session.arena, modified, page.view_id);
    }

    pub fn user_id(page: *const Page) []const u8 {
        std.debug.assert(page.session.signed_in());
        std.debug.assert(page.session.ctx.now_ms > 0);

        return page.session.ctx.caller.user_id() orelse "";
    }

    pub fn type_named(page: *const Page, handle: []const u8) ?Summary {
        std.debug.assert(handle.len > 0);
        std.debug.assert(page.types.len <= 4096);

        for (page.types) |summary| {
            if (std.mem.eql(u8, summary.handle, handle)) {
                return summary;
            }
        }

        return null;
    }
};

pub fn list(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const arena = session.arena;
    const query = request.query();
    const address = try filters.parse(arena, query);

    if (try redirect_by_kind(&session, address)) {
        return;
    }

    const listed_types = registry.SDK.dispatch(&session.ctx, types.List, .{
        .limit = @import("../../../sdk/operation.zig").page_limit_max,
    }) catch |err| return admin.fail(&session, err, "/admin");
    const view_id = admin.query_param(&session, "view");
    const saved = try saved_of(&session, view_id) orelse if (view_id != null) return else null;
    const base: Filters = if (saved) |found|
        model.view.decode(arena, found.query) catch Filters{}
    else
        address;
    const typed = try view_offer.of(&session, base);
    const offer = typed orelse view_offer.across_types();
    const resting = if (saved != null)
        base
    else if (base.type_view and typed != null)
        view_offer.start(arena, typed.?)
    else
        try default_base(arena, address, listed_types.types);

    const given = if (view_id != null and filters.any_present(query)) address else base;
    const started = if (saved == null and base.type_view and filters.bare(query))
        resting
    else
        filters.completed(given, resting);
    const effective = try view_offer.kept(arena, started, offer);
    var page: Page = .{
        .session = &session,
        .query = query,
        .view_id = view_id,
        .saved = saved,
        .effective = effective,
        .changed = !(try filters.same(arena, effective, resting)),
        .types = listed_types.types,
        .statuses = statuses.known(&session.ctx) catch |err| return admin.fail(&session, err, back),
        .offer = offer,
        .resting = resting,
        .default_columns = if (typed) |found|
            view_offer.start(arena, found).columns orelse &view_offer.across_default_columns
        else
            &view_offer.across_default_columns,
    };
    var list_in = try filters.list_in(arena, effective);
    list_in.variant = @import("../variant.zig").chosen(&session);
    list_in.count = true;

    const shown = listed_page(&session, &list_in) catch |err| {
        return admin.fail(&session, err, back);
    };
    var props = try base_props(&page, shown.listed.total);
    try fill_header(&props, &page);
    try pills.fill(&props, &page);
    try table.fill(&props, &page, shown.listed.records);
    try table.fill_selection(&props, &page, list_in, shown.listed.total);
    try table.fill_pages(&props, &page, shown.number, shown.listed.total);
    try @import("view_options.zig").fill(&props, &page);
    try session.response.set_header("Vary", "Accept");
    try session.response.set_header("Cache-Control", "private, no-cache");

    if (std.mem.eql(u8, request.header("accept") orelse "", "application/json")) {
        return table.answer(&session, props);
    }

    const list_panel = try admin.render.view(arena, views.ContentList, props);

    try admin.screen(
        &session,
        .ok,
        views.Content,
        .{
            .title = props.title,
            .has_types = has_record_type(page.types),
            .list = list_panel,
        },
        .{
            .content = .{
                .view_id = view_id,
                .filters = effective,
            },
        },
    );
}

/// One page of the records, the address's `page` (from 1). Past the last one (its records
/// moved away, an old link) the last one is shown instead.
fn listed_page(session: *Session, list_in: *record_operations.List.In) !Shown {
    std.debug.assert(list_in.limit > 0 and list_in.limit <= record_operations.list_max);
    std.debug.assert(list_in.count);

    const asked = admin.query_param(session, "page") orelse "1";
    const per_page = list_in.limit;
    var number = std.math.clamp(std.fmt.parseInt(u32, asked, 10) catch 1, 1, pages_max);

    list_in.offset = (number - 1) * per_page;

    var listed = try registry.SDK.dispatch(&session.ctx, record_operations.List, list_in.*);
    const last = table.page_count(listed.total, per_page);

    if (number > last) {
        number = last;
        list_in.offset = (number - 1) * per_page;
        listed = try registry.SDK.dispatch(&session.ctx, record_operations.List, list_in.*);
    }

    return .{
        .listed = listed,
        .number = number,
    };
}

const Shown = struct {
    listed: record_operations.List.Out,
    number: u32,
};

/// Pages an address may ask for: every offset they make, at the most rows a page holds,
/// fits a `u32`.
const pages_max: u32 = std.math.maxInt(u32) / 100;

/// The page with what every part of it shares filled in; the header, the pills and the
/// rows follow.
fn base_props(page: *const Page, total: u32) Error!views.ContentList.Props {
    std.debug.assert(page.query.len <= filters.query_len_max);
    std.debug.assert(page.session.signed_in());

    const session = page.session;

    return .{
        .csrf = session.csrf_token(),
        .title = try title_of(page),
        .address = try page.href(page.effective),
        .shown_text = try session.translated_count("{count} record", "{count} records", total),
        .is_saved = page.saved != null,
        .view_id = page.view_id orelse "",
        .view_changed = page.changed,
        .base_href = try base_href(page),
        .filters_query = try filters_query(page),
        .copy_name = "",
        .save_href = "",
        .delete_href = "",
        .rename_href = "",
        .default_type = if (page.saved == null and page.effective.type_view and
            page.offer.?.title_field.len > 0)
            page.effective.types[0]
        else
            "",
        .own_default = if (page.offer) |offer| std.mem.eql(u8, offer.layer, "mine") else false,
        .everyone_default = if (page.offer) |offer| offer.everyone else false,
        .is_admin = session.ctx.caller.holds("admin"),
        .view_shared = if (page.saved) |saved| saved.shared else false,
        .new_href = "",
        .new_label = try session.translated("New record", .{}),
        .new_targets = &.{},
        .hidden = &.{},
        .search = page.effective.search orelse "",
        .add_filters = &.{},
        .show_type = !page.effective.type_view,
        .empty_text = "",
        .columns = &.{},
        .rows = &.{},
        .filters = &.{},
        .total = 0,
        .match_type = "",
        .match_types = &.{},
        .match_filters = &.{},
        .match_search = "",
        .transitions = &.{},
        .pages = &.{},
        .previous_href = "",
        .next_href = "",
        .range_text = "",
        .sort_options = &.{},
        .direction_options = &.{},
        .page_size_options = &.{},
        .properties = &.{},
    };
}

/// A settings type has one record: its settings editor. A component has
/// none: its fields page. Only a plain `?type=<handle>` address goes there. Answers true
/// when it redirected.
fn redirect_by_kind(session: *Session, address: Filters) Error!bool {
    std.debug.assert(session.signed_in());
    std.debug.assert(address.types.len <= model.view.types_max);

    if (!address.type_view or address.types.len != 1) {
        return false;
    }

    const handle = address.types[0];
    const got = registry.SDK.dispatch(&session.ctx, types.Get, .{
        .type = handle,
    }) catch |err| {
        try admin.fail(session, err, back);

        return true;
    };

    switch (got.definition.kind) {
        .record => return false,
        .component => {
            const fields_page = try print(session.arena, "/admin/components/{s}", .{handle});

            try session.response.redirect(.see_other, fields_page);

            return true;
        },
        .settings => {
            const location = try print(session.arena, "/admin/settings/{s}", .{handle});
            try session.response.redirect(.see_other, location);
            return true;
        },
        // Files show where their owner draws them; the library's own on its page.
        .media => {
            if (model.media.is_library(handle)) {
                try session.response.redirect(.see_other, "/admin/media");
            } else {
                try admin.fail(session, error.NotFound, back);
            }

            return true;
        },
    }
}

/// The saved view the address names; a not-found page (and null) when it is not the
/// caller's. Null without a page when none is named.
fn saved_of(session: *Session, view_id: ?[]const u8) Error!?saved_views.Saved {
    std.debug.assert(session.signed_in());

    const id = view_id orelse return null;

    std.debug.assert(id.len > 0);

    const got = registry.SDK.dispatch(&session.ctx, saved_views.Get, .{
        .id = id,
    }) catch |err| {
        try admin.fail(session, err, back);

        return null;
    };

    return got.view;
}

fn has_record_type(listed: []const Summary) bool {
    std.debug.assert(listed.len <= 4096);
    std.debug.assert(back.len > 0);

    for (listed) |summary| {
        if (summary.kind == .record) {
            return true;
        }
    }

    return false;
}

/// The saved view's name; one type's name; a built-in view's; else the whole content.
fn title_of(page: *const Page) Error![]const u8 {
    std.debug.assert(page.session.signed_in());
    std.debug.assert(page.effective.types.len <= model.view.types_max);

    if (page.saved) |saved| {
        return saved.name;
    }

    if (page.effective.type_view and page.effective.types.len == 1) {
        if (page.type_named(page.effective.types[0])) |summary| {
            return summary.name;
        }
    }

    for (built_in_views, 0..) |candidate, index| {
        if (try filters.same(page.session.arena, page.effective, candidate.filter)) {
            return built_in_name(page.session, @intCast(index));
        }
    }

    return page.session.translated("All content", .{});
}

/// A built-in view's name, by its place in `built_in_views`.
fn built_in_name(session: *const Session, index: u32) Error![]const u8 {
    std.debug.assert(index < built_in_views.len);
    std.debug.assert(built_in_views.len == 4);

    return switch (index) {
        0 => session.translated("Recent", .{}),
        1 => session.translated("Created by me", .{}),
        2 => session.translated("Updated by me", .{}),
        else => session.translated("Changed", .{}),
    };
}

/// The view the filters rest on when no saved view is shown: a type's own view, a built-in
/// view when they are exactly it, else the whole content. Anything on top of it is a
/// change, to clear or to save as a view.
fn default_base(
    arena: std.mem.Allocator,
    effective: Filters,
    listed: []const Summary,
) Error!Filters {
    std.debug.assert(effective.types.len <= model.view.types_max);
    std.debug.assert(listed.len <= 4096);

    if (effective.type_view) {
        return .{
            .types = effective.types,
            .type_view = true,
        };
    }

    for (built_in_views) |candidate| {
        if (try filters.same(arena, effective, candidate.filter)) {
            return candidate.filter;
        }
    }

    return .{};
}

const built_in_views = [_]struct {
    filter: Filters,
}{
    .{
        .filter = admin.nav.recent,
    },
    .{
        .filter = admin.nav.created_by_me,
    },
    .{
        .filter = admin.nav.updated_by_me,
    },
    .{
        .filter = admin.nav.changed_only,
    },
};

/// Where "Clear changes" goes: the saved view as saved, or the view the filters rest on.
fn base_href(page: *const Page) Error![]const u8 {
    std.debug.assert(page.query.len <= filters.query_len_max);

    if (page.view_id) |id| {
        return print(page.session.arena, "/admin/content?view={s}", .{id});
    }

    return filters.format(page.session.arena, page.resting, null);
}

/// The filters in force as the query string a form posts to save them.
fn filters_query(page: *const Page) Error![]const u8 {
    std.debug.assert(page.query.len <= filters.query_len_max);

    const address = try filters.format(page.session.arena, page.effective, null);
    const question = std.mem.indexOfScalar(u8, address, '?') orelse return "";

    return address[question + 1 ..];
}

/// The view menu's targets and names, and the way to a new record.
fn fill_header(props: *views.ContentList.Props, page: *const Page) Error!void {
    std.debug.assert(props.title.len > 0);
    std.debug.assert(page.types.len <= 4096);

    const session = page.session;
    const arena = session.arena;

    if (page.view_id) |id| {
        props.save_href = try print(arena, "/admin/views/{s}/save", .{id});
        props.rename_href = try print(arena, "/admin/views/{s}/rename", .{id});
        props.delete_href = try print(arena, "/admin/views/{s}/delete", .{id});
        props.copy_name = try session.translated("New view", .{});
    } else {
        props.copy_name = try session.translated(
            "Copy of {view}",
            .{
                .values = &.{.{
                    .name = "view",
                    .value = props.title,
                }},
            },
        );
    }

    var targets: std.ArrayList(views.ContentList.New_targetsItem) = .empty;

    for (page.types) |summary| {
        const hidden = model.design.is_design(summary.handle);

        if (summary.kind != .record or hidden) {
            continue;
        }

        if (page.effective.types.len > 0 and !contains(page.effective.types, summary.handle)) {
            continue;
        }

        targets.append(arena, .{
            .label = summary.name,
            .href = try print(arena, "/admin/content/new?type={s}", .{summary.handle}),
        }) catch return error.OutOfMemory;
    }

    if (targets.items.len == 1) {
        props.new_href = targets.items[0].href;
        props.new_label = try session.translated(
            "New {type}",
            .{
                .values = &.{.{
                    .name = "type",
                    .value = targets.items[0].label,
                }},
            },
        );
    } else {
        props.new_targets = targets.items;
    }
}

pub fn contains(handles: []const []const u8, item: []const u8) bool {
    std.debug.assert(handles.len <= model.view.types_max);
    std.debug.assert(item.len > 0);

    for (handles) |candidate| {
        if (std.mem.eql(u8, candidate, item)) {
            return true;
        }
    }

    return false;
}

fn print(arena: std.mem.Allocator, comptime format: []const u8, args: anytype) Error![]const u8 {
    std.debug.assert(format.len > 0);

    return std.fmt.allocPrint(arena, format, args) catch return error.OutOfMemory;
}
