//! The view options behind the knob beside Filter: what to sort by and which way, how many
//! rows a page shows, and the properties: the columns shown, in their order (dragged into
//! another), then the rest. Every choice is the list's address with it made.
const std = @import("std");
const admin = @import("../../admin.zig");
const model = @import("../../../model.zig");
const list = @import("list.zig");
const view_offer = @import("view_offer.zig");
const view_table = @import("view_table.zig");

const Error = admin.Error;
const Props = admin.views.ContentList.Props;
const Page = list.Page;
const Filters = model.view.Filters;

pub fn fill(props: *Props, page: *const Page) Error!void {
    std.debug.assert(page.session.signed_in());

    const offer = page.offer orelse return;

    try fill_sort(props, page, offer);
    try fill_page_sizes(props, page);
    try fill_properties(props, page, offer);
}

fn fill_sort(props: *Props, page: *const Page, offer: view_offer.Offer) Error!void {
    std.debug.assert(offer.orderable.len > 0);

    const session = page.session;
    const arena = session.arena;
    const order = (page.effective.order orelse "-updated");
    const descending = std.mem.startsWith(u8, order, "-");
    const current = if (descending) order[1..] else order;
    var sort: std.ArrayList(admin.views.ContentList.Sort_optionsItem) = .empty;

    for (offer.orderable) |named| {
        sort.append(arena, .{
            .id = named.name,
            .label = try label_of(session, named),
            .href = try ordered(page, named.name, descending),
            .selected = std.mem.eql(u8, named.name, current),
        }) catch return error.OutOfMemory;
    }

    const directions = arena.alloc(admin.views.ContentList.Direction_optionsItem, 2) catch {
        return error.OutOfMemory;
    };

    directions[0] = .{
        .key = try ordered(page, current, false),
        .label = try session.translated("Ascending", .{}),
        .icon = .@"arrow-up",
        .pressed = !descending,
    };
    directions[1] = .{
        .key = try ordered(page, current, true),
        .label = try session.translated("Descending", .{}),
        .icon = .@"arrow-down",
        .pressed = descending,
    };
    props.sort_options = sort.items;
    props.direction_options = directions;
}

fn fill_page_sizes(props: *Props, page: *const Page) Error!void {
    std.debug.assert(model.view.per_page_choices.len == 4);

    const arena = page.session.arena;
    const sizes = arena.alloc(admin.views.ContentList.Page_size_optionsItem, 4) catch {
        return error.OutOfMemory;
    };

    for (model.view.per_page_choices, sizes) |choice, *size| {
        var changed = page.effective;
        changed.per_page = choice;

        size.* = .{
            .key = try page.href(changed),
            .label = std.fmt.allocPrint(arena, "{d}", .{choice}) catch return error.OutOfMemory,
            .pressed = choice == page.per_page(),
        };
    }

    props.page_size_options = sizes;
}

/// Every column the list can show but its title: the shown ones in their order, then the
/// rest; each with the address that shows or hides it.
fn fill_properties(props: *Props, page: *const Page, offer: view_offer.Offer) Error!void {
    std.debug.assert(offer.columns.len <= model.view.columns_max + 8);

    const session = page.session;
    const arena = session.arena;
    const shown = page.columns();
    var properties: std.ArrayList(admin.views.ContentList.PropertiesItem) = .empty;

    for (shown) |name| {
        const named = view_offer.find_named(offer.columns, name) orelse continue;

        properties.append(arena, .{
            .id = named.name,
            .label = try label_of(session, named),
            .shown = true,
            .show_href = try page.href(try view_table.without_column(page, named.name)),
        }) catch return error.OutOfMemory;
    }

    for (offer.columns) |named| {
        if (std.mem.eql(u8, named.name, offer.title_field) or listed(shown, named.name)) {
            continue;
        }

        properties.append(arena, .{
            .id = named.name,
            .label = try label_of(session, named),
            .shown = false,
            .show_href = try page.href(try with_column(page, named.name)),
        }) catch return error.OutOfMemory;
    }

    props.properties = properties.items;
}

fn label_of(session: *const admin.Session, named: anytype) Error![]const u8 {
    std.debug.assert(named.name.len > 0);

    const core = try view_table.core_label(session, named.name);

    return if (core.ptr != named.name.ptr) core else session.declared(named.label);
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

fn with_column(page: *const Page, name: []const u8) Error!Filters {
    std.debug.assert(name.len > 0);

    const arena = page.session.arena;
    var names: std.ArrayList([]const u8) = .empty;

    names.appendSlice(arena, page.columns()) catch return error.OutOfMemory;
    names.append(arena, name) catch return error.OutOfMemory;

    var changed = page.effective;
    changed.columns = names.items;

    return changed;
}

fn listed(names: []const []const u8, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) {
            return true;
        }
    }

    return false;
}
