//! What a one-type list offers (`view.default`): the columns it can show, the fields to
//! filter and order by, and the default view it starts at. A view the address or a saved
//! view names keeps only what the type offers.
const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const model = @import("../../../model.zig");
const view_default = @import("../../../operations/view_default.zig");

const Filters = model.view.Filters;
const Clause = model.filter.Clause;
const Error = admin.Error;

pub const Offer = view_default.Default.Out;

/// The offer of the one type a view covers; null for a view over several types, or a type
/// the caller cannot read.
pub fn of(session: *admin.Session, filters: Filters) Error!?Offer {
    std.debug.assert(session.signed_in());
    std.debug.assert(filters.types.len <= model.view.types_max);

    if (filters.types.len != 1) {
        return null;
    }

    var reading = session.*;

    return registry.SDK.dispatch(&reading.ctx, view_default.Default, .{
        .type = filters.types[0],
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

/// What a list across types offers: core's columns and orders, the page size; no field to
/// filter by, a field meaning something within one type only.
pub fn across_types() Offer {
    return .{
        .query = "{}",
        .layer = "core",
        .everyone = false,
        .title_field = "",
        .columns = &across_columns,
        .filterable = &.{},
        .orderable = &across_orders,
    };
}

const across_columns = [_]view_default.Named{
    .{
        .name = "type",
        .label = "Content type",
    },
    .{
        .name = "slug",
        .label = "Slug",
    },
    .{
        .name = "status",
        .label = "Status",
    },
    .{
        .name = "updated",
        .label = "Updated",
    },
    .{
        .name = "created",
        .label = "Created",
    },
};
const across_orders = [_]view_default.Named{
    .{
        .name = "title",
        .label = "Title",
    },
    .{
        .name = "created",
        .label = "Created",
    },
    .{
        .name = "updated",
        .label = "Updated",
    },
    .{
        .name = "status",
        .label = "Status",
    },
};

/// The columns a list across types shows when its view says none.
pub const across_default_columns = [_][]const u8{ "type", "slug", "status", "updated" };

/// The view the offer starts at.
pub fn start(arena: std.mem.Allocator, offer: Offer) Filters {
    std.debug.assert(offer.query.len > 0);

    return model.view.decode(arena, offer.query) catch .{};
}

/// The view with only what the type offers: clauses on fields it filters by, with their
/// operators; columns it can show; an order it can take.
pub fn kept(arena: std.mem.Allocator, filters: Filters, offer: Offer) Error!Filters {
    std.debug.assert(filters.clauses.len <= model.view.clauses_max);

    var out = filters;
    var clauses: std.ArrayList(Clause) = .empty;

    for (filters.clauses) |clause| {
        const field = model.field_filter.field_of(clause.key) orelse {
            clauses.append(arena, clause) catch return error.OutOfMemory;
            continue;
        };

        if (operator_of(offer, field, clause.operator) != null) {
            clauses.append(arena, clause) catch return error.OutOfMemory;
        }
    }

    out.clauses = clauses.items;
    out.columns = if (filters.columns) |names| try named(arena, names, offer.columns) else null;

    if (filters.order) |order| {
        const name = (order);
        const bare = if (std.mem.startsWith(u8, name, "-")) name[1..] else name;

        if (find_named(offer.orderable, bare) == null) {
            out.order = null;
        }
    }

    return out;
}

/// The field to filter by, as the offer has it.
pub fn filterable(offer: Offer, field: []const u8) ?view_default.Filterable {
    std.debug.assert(field.len > 0);

    for (offer.filterable) |candidate| {
        if (std.mem.eql(u8, candidate.name, field)) {
            return candidate;
        }
    }

    return null;
}

pub fn operator_of(offer: Offer, field: []const u8, id: []const u8) ?view_default.Operator {
    std.debug.assert(field.len > 0);

    const found = filterable(offer, field) orelse return null;

    for (found.operators) |operator| {
        if (std.mem.eql(u8, operator.id, id)) {
            return operator;
        }
    }

    return null;
}

pub fn find_named(list: []const view_default.Named, name: []const u8) ?view_default.Named {
    std.debug.assert(list.len <= model.view.columns_max + model.view.core_orders.len);

    for (list) |candidate| {
        if (std.mem.eql(u8, candidate.name, name)) {
            return candidate;
        }
    }

    return null;
}

fn named(
    arena: std.mem.Allocator,
    names: []const []const u8,
    offered: []const view_default.Named,
) Error![]const []const u8 {
    std.debug.assert(names.len <= model.view.columns_max);

    var out: std.ArrayList([]const u8) = .empty;

    for (names) |name| {
        if (find_named(offered, name) != null) {
            out.append(arena, name) catch return error.OutOfMemory;
        }
    }

    return out.items;
}
