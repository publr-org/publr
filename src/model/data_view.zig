//! A type's default view of its list, from its layers: the type's fields say what can be
//! filtered and ordered (`filterable`, `sortable`) and core offers every column a cell can
//! show; the type's plugin says where the list starts (`content_type.View`); the
//! administrators' view for everyone and the person's own each replace the start whole.

const std = @import("std");
const content_type = @import("content_type.zig");
const field = @import("field.zig");
const field_filter = @import("field_filter.zig");
const kinds = @import("kinds.zig");
const view = @import("view.zig");

/// Core's columns a list may show besides the type's fields, in the order offered.
pub const core_columns = [_][]const u8{ "slug", "status", "updated", "created" };
/// What a type's list shows when nothing says otherwise, after the plugin's columns.
const default_columns = [_][]const u8{ "slug", "status", "updated" };
pub const per_page_default: u32 = 20;

pub const Error = error{OutOfMemory};

/// Where the start of the list came from: Reset to default goes one layer down.
pub const Layer = enum { core, plugin, everyone, mine };

/// One field a list can filter by: its family says which operators and values.
pub const Filterable = struct {
    name: []const u8,
    label: []const u8,
    family: field_filter.Family,
    many: bool,
};

pub const Resolved = struct {
    /// The list as it starts for this person, one type's own view.
    start: view.Filters,
    layer: Layer,
    /// What the view options offer: every column; the fields to filter and order by.
    columns: []const []const u8,
    filterable: []const Filterable,
    orderable: []const []const u8,
};

pub const Layers = struct {
    handle: []const u8,
    fields: []const field.Def,
    plugin: content_type.View = .{},
    everyone: ?view.Filters = null,
    mine: ?view.Filters = null,
};

/// The type's default view for one person.
pub fn resolve(
    arena: std.mem.Allocator,
    known: []const kinds.Kind,
    layers: Layers,
) Error!Resolved {
    std.debug.assert(layers.handle.len > 0);
    std.debug.assert(layers.fields.len <= field.fields_max);

    const filterable = try filterable_of(arena, known, layers);
    const orderable = try orderable_of(arena, known, layers);
    const layer: Layer = if (layers.mine != null)
        .mine
    else if (layers.everyone != null)
        .everyone
    else if (has_plugin(layers.plugin))
        .plugin
    else
        .core;
    var start = layers.mine orelse layers.everyone orelse try plugin_start(arena, layers);

    start.types = arena.dupe([]const u8, &.{layers.handle}) catch return error.OutOfMemory;
    start.type_view = true;

    return .{
        .start = start,
        .layer = layer,
        .columns = try columns_of(arena, known, layers.fields),
        .filterable = filterable,
        .orderable = orderable,
    };
}

fn has_plugin(plugin: content_type.View) bool {
    return plugin.columns.len > 0 or plugin.filters.len > 0 or plugin.order != null;
}

/// Where the plugin starts the list, or core's start: its columns then slug, status and
/// updated; newest saved first.
fn plugin_start(arena: std.mem.Allocator, layers: Layers) Error!view.Filters {
    std.debug.assert(layers.handle.len > 0);

    var columns: std.ArrayList([]const u8) = .empty;

    for (layers.plugin.columns) |name| {
        columns.append(arena, name) catch return error.OutOfMemory;
    }

    for (default_columns) |name| {
        if (!contains(columns.items, name)) {
            columns.append(arena, name) catch return error.OutOfMemory;
        }
    }

    return .{
        .clauses = layers.plugin.filters,
        .order = layers.plugin.order orelse "-updated",
        .columns = columns.items,
        .per_page = per_page_default,
    };
}

/// Every field that holds a value (not a tab, an accordion or a message), then core's
/// columns.
fn columns_of(
    arena: std.mem.Allocator,
    known: []const kinds.Kind,
    fields: []const field.Def,
) Error![]const []const u8 {
    std.debug.assert(fields.len <= field.fields_max);

    var columns: std.ArrayList([]const u8) = .empty;

    for (fields) |one| {
        std.debug.assert(known.len > 0);

        if (!field.is_layout(one.kind)) {
            columns.append(arena, one.name) catch return error.OutOfMemory;
        }
    }

    // A field named like one of core's columns (`slug`) is that column.
    for (core_columns) |name| {
        if (!contains(columns.items, name)) {
            columns.append(arena, name) catch return error.OutOfMemory;
        }
    }

    return columns.items;
}

fn filterable_of(
    arena: std.mem.Allocator,
    known: []const kinds.Kind,
    layers: Layers,
) Error![]const Filterable {
    std.debug.assert(layers.fields.len <= field.fields_max);

    var out: std.ArrayList(Filterable) = .empty;

    for (layers.fields) |one| {
        const kind = kinds.lookup(known, one.kind);
        const family = field_filter.family_of(kind);

        if (family != .none and one.filterable) {
            out.append(arena, .{
                .name = one.name,
                .label = one.label,
                .family = family,
                .many = one.many,
            }) catch return error.OutOfMemory;
        }
    }

    return out.items;
}

/// Core's orders, then every field the type orders by (`sortable`, else as its kind does).
fn orderable_of(
    arena: std.mem.Allocator,
    known: []const kinds.Kind,
    layers: Layers,
) Error![]const []const u8 {
    std.debug.assert(layers.fields.len <= field.fields_max);

    var out: std.ArrayList([]const u8) = .empty;

    out.appendSlice(arena, &view.core_orders) catch return error.OutOfMemory;

    for (layers.fields) |one| {
        const family = field_filter.family_of(kinds.lookup(known, one.kind));
        const wanted = one.sortable orelse field_filter.sorts_by_default(family);
        // A field named like one of core's orders (`title`) is that order.
        const core = contains(&view.core_orders, one.name);

        if (!one.many and field_filter.sortable(family) and wanted and !core) {
            out.append(arena, one.name) catch return error.OutOfMemory;
        }
    }

    return out.items;
}

/// The names of a person's view that the offer holds: a field the plugin no longer offers
/// drops out of a view saved before.
pub fn kept(
    arena: std.mem.Allocator,
    names: []const []const u8,
    offered: []const []const u8,
) Error![]const []const u8 {
    std.debug.assert(names.len <= view.columns_max);
    std.debug.assert(offered.len <= view.columns_max + view.core_orders.len);

    var out: std.ArrayList([]const u8) = .empty;

    for (names) |name| {
        if (contains(offered, name)) {
            out.append(arena, name) catch return error.OutOfMemory;
        }
    }

    return out.items;
}

fn contains(names: []const []const u8, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) {
            return true;
        }
    }

    return false;
}

const testing = std.testing;
const test_fields = [_]field.Def{
    .{
        .name = "number",
        .label = "Number",
        .kind = "integer",
    },
    .{
        .name = "notes",
        .label = "Notes",
        .kind = "richtext",
    },
    .{
        .name = "tags",
        .label = "Tags",
        .kind = "reference",
        .many = true,
    },
    .{
        .name = "name",
        .label = "Name",
        .kind = "string",
        .sortable = true,
    },
    .{
        .name = "secret_note",
        .label = "Secret note",
        .kind = "string",
        .filterable = false,
    },
};

test "the fields say what filters and orders; the plugin starts the list; later layers win" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const known = &kinds.core;

    const bare = try resolve(arena, known, .{
        .handle = "order",
        .fields = &test_fields,
    });
    try testing.expectEqual(Layer.core, bare.layer);
    try testing.expectEqual(@as(usize, 3), bare.filterable.len);
    try testing.expectEqualStrings("tags", bare.filterable[1].name);
    try testing.expectEqualStrings("name", bare.filterable[2].name);
    // Core's four, the number by its kind, the name because its type says so.
    try testing.expectEqual(@as(usize, 6), bare.orderable.len);
    try testing.expectEqualStrings("name", bare.orderable[5]);
    // Every field holding a value is a column: a long text and references too.
    try testing.expectEqualStrings("notes", bare.columns[1]);
    try testing.expectEqualStrings("-updated", bare.start.order.?);
    try testing.expectEqualStrings("slug", bare.start.columns.?[0]);
    try testing.expect(bare.start.type_view);

    const started = try resolve(arena, known, .{
        .handle = "order",
        .fields = &test_fields,
        .plugin = .{
            .columns = &.{"number"},
            .order = "-number",
        },
    });
    try testing.expectEqual(Layer.plugin, started.layer);
    try testing.expectEqualStrings("number", started.start.columns.?[0]);
    try testing.expectEqualStrings("-number", started.start.order.?);

    const mine = try resolve(arena, known, .{
        .handle = "order",
        .fields = &test_fields,
        .everyone = .{
            .order = "title",
        },
        .mine = .{
            .order = "number",
            .per_page = 50,
        },
    });
    try testing.expectEqual(Layer.mine, mine.layer);
    try testing.expectEqualStrings("number", mine.start.order.?);
    try testing.expectEqualStrings("order", mine.start.types[0]);
    const orderable = try kept(arena, &.{ "number", "gone" }, started.orderable);
    try testing.expectEqual(@as(usize, 1), orderable.len);
}
