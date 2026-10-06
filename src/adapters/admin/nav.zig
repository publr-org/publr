//! The Content section's sidebar: the ways of looking at the content, rendered once per
//! page (`views.ContentNav`) and handed to the page as a node.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const types = @import("../../operations/content_type.zig");
const saved_views = @import("../../operations/view.zig");
const filters = @import("content/filters.zig");

const Error = admin.Error;
const Session = admin.Session;
const views = admin.views;
const Filters = model.view.Filters;

/// Where the page stands: the saved view it shows, if one, and the filters in force.
pub const Current = struct { view_id: ?[]const u8 = null, filters: Filters = .{} };

const Clause = model.filter.Clause;

pub const recent: Filters = .{
    .clauses = &.{.{ .key = "updated", .operator = "within", .value = "7d" }},
};
pub const created_by_me: Filters = .{
    .clauses = &.{.{ .key = "created", .operator = "by", .value = model.view.me }},
};
pub const updated_by_me: Filters = .{
    .clauses = &.{.{ .key = "updated", .operator = "by", .value = model.view.me }},
};
pub const changed_only: Filters = .{
    .clauses = &.{.{ .key = "changed", .operator = "is", .value = "pending" }},
};

const Row = views.ContentNav.StatusesItem;

pub fn nav_content(session: *Session, current: Current) Error!admin.render.Node {
    std.debug.assert(session.signed_in());
    std.debug.assert(session.ctx.now_ms > 0);

    const arena = session.arena;
    const address = try filters.format(arena, current.filters, null);
    const on_view = current.view_id != null;
    const listed = registry.SDK.dispatch(&session.ctx, types.List, .{}) catch {
        return error.OutOfMemory;
    };
    var private: std.ArrayList(views.ContentNav.Private_viewsItem) = .empty;
    var statuses: std.ArrayList(Row) = .empty;
    var record_types: std.ArrayList(views.ContentNav.TypesItem) = .empty;

    try append_built_in(arena, &private, address, on_view);
    try append_saved(session, &private, current.view_id);

    for (registry.Statuses.all) |status| {
        const clauses = [_]Clause{.{ .key = "status", .operator = "is", .value = status.id }};
        const by_status: Filters = .{ .clauses = &clauses };
        const row = try row_of(arena, status.label, by_status, address, on_view);
        statuses.append(arena, row) catch return error.OutOfMemory;
    }

    statuses.append(arena, try row_of(arena, "Changed", changed_only, address, on_view)) catch {
        return error.OutOfMemory;
    };

    for (listed.types) |summary| {
        if (model.media.is_library(summary.handle)) {
            continue;
        }

        const one_type: Filters = .{ .types = &.{summary.handle}, .type_view = true };
        const row = try row_of(arena, summary.name, one_type, address, on_view);
        const appended = switch (summary.kind) {
            .record => record_types.append(arena, .{
                .label = row.label,
                .href = row.href,
                .active = row.active,
            }),
            .settings => {},
            .component => {},
        };

        appended catch return error.OutOfMemory;
    }

    const all = try row_of(arena, "All", .{}, address, on_view);
    const recent_row = try row_of(arena, "Recent", recent, address, on_view);

    return admin.render.view(arena, views.ContentNav, .{
        .all_href = all.href,
        .all_active = all.active,
        .recent_href = recent_row.href,
        .recent_active = recent_row.active,
        .private_views = private.items,
        .statuses = statuses.items,
        .types = record_types.items,
        .settings = &.{},
    });
}

/// One row: active when the page shows exactly these filters and no saved view.
fn row_of(
    arena: std.mem.Allocator,
    label: []const u8,
    filter: Filters,
    address: []const u8,
    on_view: bool,
) Error!Row {
    std.debug.assert(label.len > 0);
    std.debug.assert(std.mem.startsWith(u8, address, "/admin/content"));

    const href = try filters.format(arena, filter, null);

    return .{ .label = label, .href = href, .active = !on_view and std.mem.eql(u8, href, address) };
}

/// The two private views everyone has, locked: what the caller created, what they saved.
fn append_built_in(
    arena: std.mem.Allocator,
    private: *std.ArrayList(views.ContentNav.Private_viewsItem),
    address: []const u8,
    on_view: bool,
) Error!void {
    std.debug.assert(private.items.len == 0);
    std.debug.assert(std.mem.startsWith(u8, address, "/admin/content"));

    const built_in = [_]struct { label: []const u8, filter: Filters }{
        .{ .label = "Created by me", .filter = created_by_me },
        .{ .label = "Updated by me", .filter = updated_by_me },
    };

    for (built_in) |entry| {
        const row = try row_of(arena, entry.label, entry.filter, address, on_view);

        private.append(arena, .{
            .label = row.label,
            .href = row.href,
            .active = row.active,
            .locked = true,
        }) catch return error.OutOfMemory;
    }
}

/// The caller's saved views, the one shown marked; none when the caller may have none.
fn append_saved(
    session: *Session,
    private: *std.ArrayList(views.ContentNav.Private_viewsItem),
    view_id: ?[]const u8,
) Error!void {
    std.debug.assert(session.signed_in());
    std.debug.assert(private.items.len == 2);

    const mine = registry.SDK.dispatch(&session.ctx, saved_views.List, .{}) catch |err| {
        return if (err == error.Denied) {} else error.OutOfMemory;
    };

    for (mine.views) |saved| {
        const href = std.fmt.allocPrint(session.arena, "/admin/content?view={s}", .{
            saved.id,
        }) catch return error.OutOfMemory;
        const active = view_id != null and std.mem.eql(u8, view_id.?, saved.id);

        private.append(session.arena, .{
            .label = saved.name,
            .href = href,
            .active = active,
            .locked = false,
        }) catch return error.OutOfMemory;
    }
}
