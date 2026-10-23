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
pub const Current = struct {
    view_id: ?[]const u8 = null,
    filters: Filters = .{},
};

const Clause = model.filter.Clause;

pub const recent: Filters = .{
    .clauses = &.{.{
        .key = "updated",
        .operator = "within",
        .value = "7d",
    }},
};
pub const created_by_me: Filters = .{
    .clauses = &.{.{
        .key = "created",
        .operator = "by",
        .value = model.view.me,
    }},
};
pub const updated_by_me: Filters = .{
    .clauses = &.{.{
        .key = "updated",
        .operator = "by",
        .value = model.view.me,
    }},
};
pub const changed_only: Filters = .{
    .clauses = &.{.{
        .key = "changed",
        .operator = "is",
        .value = "pending",
    }},
};

const Row = views.ContentNav.StatusesItem;

pub fn nav_content(session: *Session, current: Current) Error!admin.render.Node {
    std.debug.assert(session.signed_in());
    std.debug.assert(session.ctx.now_ms > 0);

    const arena = session.arena;
    const address = try filters.format(arena, current.filters, null);
    const on_view = current.view_id != null;
    const listed = registry.SDK.dispatch(&session.ctx, types.List, .{
        .limit = @import("../../sdk/operation.zig").page_limit_max,
    }) catch {
        return error.OutOfMemory;
    };
    var private: std.ArrayList(views.ContentNav.Private_viewsItem) = .empty;
    var statuses: std.ArrayList(Row) = .empty;
    var record_types: std.ArrayList(views.ContentNav.TypesItem) = .empty;

    try append_built_in(session, &private, address, on_view);
    try append_saved(session, &private, current.view_id);

    const known = @import("../../operations/status.zig").known(&session.ctx) catch {
        return error.OutOfMemory;
    };

    const own = try own_statuses(session, current.filters);

    for (known, 0..) |status, index| {
        // Core's come first; a plugin's belong to its types: listed only on one of them.
        if (index >= model.status.core_statuses.len and !named_in(own, status.id)) {
            continue;
        }

        const clauses = [_]Clause{.{
            .key = "status",
            .operator = "is",
            .value = status.id,
        }};
        const by_status: Filters = .{
            .clauses = &clauses,
        };
        const row = try row_of(arena, status.label, by_status, address, on_view);
        statuses.append(arena, row) catch return error.OutOfMemory;
    }

    const changed_label = try session.translated("Changed", .{});
    const changed_row = try row_of(arena, changed_label, changed_only, address, on_view);

    statuses.append(arena, changed_row) catch {
        return error.OutOfMemory;
    };

    const in_sections = try @import("sections.zig").all(session);

    for (listed.types) |summary| {
        // A plugin's section lists its own types; they are not listed twice.
        if (summary.menu_hidden or model.design.is_design(summary.handle) or
            @import("sections.zig").holds(in_sections, summary.handle))
        {
            continue;
        }

        // The type's own list, at the default view each person starts at.
        const one_type: Filters = .{
            .types = &.{summary.handle},
            .type_view = true,
        };
        var row = try row_of(arena, summary.name, one_type, address, on_view);
        const shown = current.filters;

        row.active = !on_view and shown.type_view and shown.types.len == 1 and
            std.mem.eql(u8, shown.types[0], summary.handle);
        const appended = switch (summary.kind) {
            .record => record_types.append(arena, .{
                .label = row.label,
                .href = row.href,
                .active = row.active,
                .heading = summary.app,
            }),
            .settings, .component, .media => {},
        };

        appended catch return error.OutOfMemory;
    }

    try group_by_app(session, record_types.items);

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
        .sections = try sections_of(session, in_sections),
        .csrf = session.csrf_token(),
        .back = address,
        .admin = session.ctx.caller.holds("admin"),
    });
}

/// The statuses of the one type a list shows, its own and those other plugins add; none
/// for a list of several types.
fn own_statuses(session: *Session, shown: Filters) Error![]const model.status.Status {
    std.debug.assert(session.signed_in());

    if (shown.types.len != 1) {
        return &.{};
    }

    const definition = @import("../../operations/record.zig").domain.definition;
    // A type that cannot be read now lists core's statuses alone.
    const found = definition.find(&session.ctx, shown.types[0]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return &.{},
    };
    const type_row = found orelse return &.{};

    return type_row.def.flow.statuses;
}

fn named_in(statuses: []const model.status.Status, id: []const u8) bool {
    std.debug.assert(id.len > 0);

    for (statuses) |status| {
        if (std.mem.eql(u8, status.id, id)) {
            return true;
        }
    }

    return false;
}

/// The record types by where they live, each group under its name: the app the admin is
/// narrowed to first, then Global, then the other apps'. `heading` comes in as the app's
/// `.name` and leaves as the label of the group an item starts, else empty. A project with
/// no apps has no groups.
const TypeItem = views.ContentNav.TypesItem;

fn group_by_app(session: *const Session, items: []TypeItem) Error!void {
    std.debug.assert(items.len <= 4096);
    std.debug.assert(session.signed_in());

    if (session.project.apps.len == 0) {
        for (items) |*item| {
            item.heading = "";
        }

        return;
    }

    const narrowed = admin.app_scope.of(session).app_name() orelse "";
    const Rank = struct {
        narrowed: []const u8,

        fn of(rank: @This(), app: []const u8) u8 {
            if (app.len > 0 and std.mem.eql(u8, app, rank.narrowed)) {
                return 0;
            }

            return if (app.len == 0) 1 else 2;
        }

        fn less(rank: @This(), left: TypeItem, right: TypeItem) bool {
            std.debug.assert(left.label.len > 0 and right.label.len > 0);

            const left_rank = rank.of(left.heading);
            const right_rank = rank.of(right.heading);

            if (left_rank != right_rank) {
                return left_rank < right_rank;
            }

            return std.mem.order(u8, left.heading, right.heading) == .lt;
        }
    };
    const rank: Rank = .{
        .narrowed = narrowed,
    };

    std.sort.insertion(TypeItem, items, rank, Rank.less);

    var previous: ?[]const u8 = null;

    for (items) |*item| {
        const app = item.heading;
        const starts = previous == null or !std.mem.eql(u8, previous.?, app);

        previous = app;
        item.heading = if (!starts)
            ""
        else if (app.len == 0)
            try session.translated("Global", .{})
        else if (session.project.find(app)) |found|
            found.spec.label
        else
            app;
    }
}

const SectionItem = views.ContentNav.SectionsItem;

fn sections_of(
    session: *Session,
    all: []const @import("sections.zig").Section,
) Error![]const SectionItem {
    std.debug.assert(session.signed_in());

    const listed = try @import("destinations.zig").content(session, all);
    const items = try session.arena.alloc(SectionItem, listed.len);

    for (listed, items) |destination, *item| {
        const Icon = @FieldType(SectionItem, "icon");
        const picked = @import("plugin_icons.zig").pick(Icon, session, destination.icon, .package);

        item.* = .{
            .label = destination.label,
            .href = destination.href,
            .icon = picked.icon,
            .custom_icon = picked.custom_icon,
            .plugin = destination.plugin,
            .page = destination.page,
            .pinned = destination.pinned,
            .shared = destination.shared,
        };
    }

    return items;
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

    return .{
        .label = label,
        .href = href,
        .active = !on_view and std.mem.eql(u8, href, address),
    };
}

/// The two private views everyone has, locked: what the caller created, what they saved.
fn append_built_in(
    session: *const Session,
    private: *std.ArrayList(views.ContentNav.Private_viewsItem),
    address: []const u8,
    on_view: bool,
) Error!void {
    std.debug.assert(private.items.len == 0);
    std.debug.assert(std.mem.startsWith(u8, address, "/admin/content"));

    const arena = session.arena;

    const built_in = [_]struct {
        label: []const u8,
        filter: Filters,
    }{
        .{
            .label = try session.translated("Created by me", .{}),
            .filter = created_by_me,
        },
        .{
            .label = try session.translated("Updated by me", .{}),
            .filter = updated_by_me,
        },
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
