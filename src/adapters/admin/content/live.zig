//! What of a record goes live, in the editor's Publishing section: a map of the combinations
//! of the site's dimensions its type's fields vary by (a grid for two, a line for one, the
//! ones held back for more), each live one opening its preview, and a dialog with the ticks.
//! A live record's ticks waiting with its pending changes show as changed.
const std = @import("std");
const admin = @import("../../admin.zig");
const fields = @import("../fields.zig");
const model = @import("../../../model.zig");
const site_dimensions = @import("../../../operations/dimensions.zig");
const page_module = @import("../preview/page.zig");

const Error = admin.Error;
const Session = admin.Session;
const views = admin.views;
const Def = model.content_type.Def;
const Value = std.json.Value;
const live_model = model.dimension.live;
const dimensions_max = model.dimension.dimensions_max;
const print = fields.print;

const Row = views.RecordLive.RowsItem;
const Cell = @typeInfo(@FieldType(Row, "cells")).pointer.child;
const Column = views.RecordLive.ColumnsItem;
const Held = views.RecordLive.HeldItem;

const back = "/admin/content";

/// A dimension the record's fields vary by, with its values, the main one first.
const Varied = struct {
    name: []const u8,
    /// Its key in an address's query (`variation`), for one chosen per request.
    param: []const u8,
    /// Its values have pages of their own (`/pl`).
    addresses: bool,
    values: []const site_dimensions.Value,
};

/// Where each combination's preview starts: the record's page, its slugs by language.
const Preview = struct {
    id: []const u8,
    app: ?[]const u8,
    type: []const u8,
    slug: ?[]const u8,
    slug_field: []const u8,
    document: ?Value,
};

/// The record's Publishing map; null when none of its fields varies by a dimension with more
/// than one value.
pub fn node_of(
    session: *Session,
    def: Def,
    row: fields.Record,
    document: ?Value,
) Error!?admin.render.Node {
    std.debug.assert(row.id.len > 0);
    std.debug.assert(session.signed_in());

    const arena = session.arena;
    const dimensions = try varied_of(session, def);

    if (dimensions.len == 0) {
        return null;
    }

    const grid = dimensions.len == 2;
    const columns = try arena.alloc(Column, if (grid) dimensions[1].values.len else 0);

    for (columns, 0..) |*column, index| {
        column.* = .{
            .label = dimensions[1].values[index].label,
        };
    }

    const preview: Preview = .{
        .id = row.id,
        .app = row.app,
        .type = row.type,
        .slug = row.slug,
        .slug_field = slug_field_of(def),
        .document = document,
    };
    const held_back = row.pending_held_back orelse row.held_back;
    var rows: std.ArrayList(Row) = .empty;
    var row_cells: std.ArrayList(Cell) = .empty;
    var held: std.ArrayList(Held) = .empty;
    var at: [dimensions_max]u32 = @splat(0);
    var cut = false;
    var offered: u32 = 0;

    // Every combination, the last dimension turning fastest; a grid's row ends with it.
    while (true) {
        if (offered == live_model.held_max) {
            cut = true;
            break;
        }

        var cell = try cell_of(arena, held_back, dimensions, &at);

        cell.changed = row.pending_held_back != null and
            live_model.held(row.held_back, cell.combination) != !cell.checked;
        cell.preview = if (cell.checked)
            try preview_of(session, preview, dimensions, &at)
        else
            "";
        try row_cells.append(arena, cell);
        offered += 1;

        if (!cell.checked) {
            try held.append(arena, .{
                .label = cell.label,
            });
        }

        if (!grid or at[1] + 1 == dimensions[1].values.len) {
            try rows.append(arena, .{
                .label = if (grid) dimensions[0].values[at[0]].label else row_cells.items[0].label,
                .cells = try row_cells.toOwnedSlice(arena),
            });
        }

        if (!advance(dimensions, &at)) {
            break;
        }
    }

    return try admin.render.view(arena, views.RecordLive, .{
        .action = try print(arena, "{s}/{s}/action", .{ back, row.id }),
        .csrf = session.csrf_token(),
        .expected_version = try print(arena, "{d}", .{row.version}),
        .shape = if (grid) "grid" else if (dimensions.len == 1) "line" else "held",
        .held = held.items,
        .columns = columns,
        .rows = rows.items,
        .cut = cut,
    });
}

/// The site's dimensions some field of `def` varies by, each with more than one value.
fn varied_of(session: *Session, def: Def) Error![]const Varied {
    std.debug.assert(def.fields.len <= model.field.fields_max);
    std.debug.assert(session.signed_in());

    var varied: std.ArrayList(Varied) = .empty;

    for (site_dimensions.all(&session.ctx)) |dimension| {
        if (!varies(def, dimension.name)) {
            continue;
        }

        const values = site_dimensions.values_of(&session.ctx, dimension) catch continue;

        if (values.len > 1) {
            try varied.append(session.arena, .{
                .name = dimension.name,
                .param = if (dimension.param.len > 0) dimension.param else dimension.name,
                .addresses = dimension.addresses,
                .values = values,
            });
        }
    }

    return varied.items;
}

/// Whether a field of `def` varies by `name`.
fn varies(def: Def, name: []const u8) bool {
    std.debug.assert(name.len > 0);
    std.debug.assert(def.fields.len <= model.field.fields_max);

    for (def.fields) |field| {
        if (model.dimension.varies_by(field.dimensions, name)) {
            return true;
        }
    }

    return false;
}

/// The name of `def`'s slug field; empty without one.
fn slug_field_of(def: Def) []const u8 {
    std.debug.assert(def.fields.len <= model.field.fields_max);

    for (def.fields) |field| {
        if (model.field.is_slug(field.kind)) {
            return field.name;
        }
    }

    return "";
}

/// The combination `at` points to: ticked unless the record holds it back.
fn cell_of(
    arena: std.mem.Allocator,
    held_back: []const u8,
    dimensions: []const Varied,
    at: *const [dimensions_max]u32,
) Error!Cell {
    std.debug.assert(dimensions.len > 0);
    std.debug.assert(dimensions.len <= dimensions_max);

    var pairs: [dimensions_max]model.dimension.Pair = undefined;
    var labels: std.ArrayList([]const u8) = .empty;

    for (dimensions, 0..) |dimension, index| {
        const value = dimension.values[at[index]];

        pairs[index] = .{
            .dimension = dimension.name,
            .code = if (value.main) "" else value.code,
        };
        try labels.append(arena, value.label);
    }

    var buffer: [live_model.combination_len_max + 2]u8 = undefined;
    const combination = live_model.combination_of(&buffer, pairs[0..dimensions.len]) orelse "";

    return .{
        .combination = try arena.dupe(u8, combination),
        .label = try std.mem.join(arena, " / ", labels.items),
        .checked = !live_model.held(held_back, combination),
        .main = combination.len == 0,
        .changed = false,
        .preview = "",
    };
}

/// The preview of the record's page in the combination `at` points to: under the address of
/// the dimension with pages of its own, by its slug there, each other dimension's value in
/// the query. Empty when no page of the site shows the record.
fn preview_of(
    session: *Session,
    preview: Preview,
    dimensions: []const Varied,
    at: *const [dimensions_max]u32,
) Error![]const u8 {
    std.debug.assert(dimensions.len > 0);
    std.debug.assert(preview.id.len > 0);

    const arena = session.arena;
    var address: []const u8 = "";
    var slug = preview.slug;
    var query: std.Io.Writer.Allocating = .init(arena);

    for (dimensions, 0..) |dimension, index| {
        const value = dimension.values[at[index]];

        if (value.main) {
            continue;
        }

        if (dimension.addresses) {
            address = value.address;
            slug = try slug_in(arena, preview, dimension.name, value.code) orelse slug;
            continue;
        }

        const lead: u8 = if (query.written().len == 0) '?' else '&';

        query.writer.print("{c}{s}={s}", .{ lead, dimension.param, value.code }) catch {
            return error.OutOfMemory;
        };
    }

    const project = session.project;
    const own = page_module.own_path(project, arena, preview.app, preview.type, slug) catch {
        return error.OutOfMemory;
    } orelse return "";
    const path = try std.mem.concat(arena, u8, &.{ address, own, query.written() });
    var encoded: std.Io.Writer.Allocating = .init(arena);

    std.Uri.Component.percentEncode(&encoded.writer, path, unreserved) catch {
        return error.OutOfMemory;
    };

    return print(arena, "/admin/preview/{s}?path={s}", .{ preview.id, encoded.written() });
}

fn unreserved(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '-' or char == '_' or char == '.' or
        char == '~' or char == '/';
}

/// The record's slug where `dimension` is at `code`, when it has one of its own there.
fn slug_in(
    arena: std.mem.Allocator,
    preview: Preview,
    dimension: []const u8,
    code: []const u8,
) Error!?[]const u8 {
    std.debug.assert(dimension.len > 0);
    std.debug.assert(code.len > 0);

    if (preview.slug_field.len == 0) {
        return null;
    }

    const document = preview.document orelse return null;

    if (document != .object) {
        return null;
    }

    const key = try print(arena, "{s}@{s}={s}", .{ preview.slug_field, dimension, code });
    const found = document.object.get(key) orelse return null;

    return if (found == .string and found.string.len > 0) found.string else null;
}

/// The next combination after `at`, the last dimension turning fastest; false past the last.
fn advance(dimensions: []const Varied, at: *[dimensions_max]u32) bool {
    std.debug.assert(dimensions.len > 0);
    std.debug.assert(dimensions.len <= dimensions_max);

    var index = dimensions.len;

    while (index > 0) {
        index -= 1;
        at[index] += 1;

        if (at[index] < dimensions[index].values.len) {
            return true;
        }

        at[index] = 0;
    }

    return false;
}
