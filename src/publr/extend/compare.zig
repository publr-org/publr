//! Two versions of a value side by side, as the admin's `CompareField` and `CompareValues`
//! draw them: each value as people see it, and what one version changed against the other.
//! `publr.Host.admin_pages.compare`, for a built-in plugin's review screens.
const std = @import("std");
const core = @import("../../adapters/admin/compare.zig");
const kinds_model = @import("../../model/kinds.zig");

/// A value as a version holds it: its JSON, its text, and for a document it points at, that
/// document's card.
pub const Value = struct {
    json: []const u8,
    text: []const u8,
    card_title: []const u8 = "",
    card_type: []const u8 = "",
    card_status: []const u8 = "",
    card_href: []const u8 = "",
};

/// A run of text, marked `same`, `added` or `removed`.
pub const Segment = struct {
    text: []const u8,
    mark: []const u8,
};

/// A value ready to draw: the fields `CompareValue` has.
pub const Shown = struct {
    json: []const u8,
    mark: []const u8,
    card: bool,
    title: []const u8 = "",
    type_label: []const u8 = "",
    status: []const u8 = "",
    tone: []const u8 = "neutral",
    href: []const u8 = "",
    segments: []const Segment = &.{},
    /// Drawn as a definition card: a field of a type, a plugin, a request it makes.
    definition: bool = false,
    icon: []const u8 = "link",
    required: bool = false,
    summary: []const u8 = "",
    name: []const u8 = "",
    details: []const []const u8 = &.{},
};

/// The field kinds the page's project knows, to show a field's definition by its kind:
/// `page.kinds()`.
pub const Kinds = struct {
    /// Publr's own.
    held: *const anyopaque,
    count: u32,

    fn list(kinds: Kinds) []const kinds_model.Kind {
        const first: [*]const kinds_model.Kind = @ptrCast(@alignCast(kinds.held));

        return first[0..kinds.count];
    }
};

const values_max: u32 = 4096;

/// Each value as people see it, unmarked.
pub fn shown(arena: std.mem.Allocator, kinds: Kinds, values: []const Value) ![]const Shown {
    std.debug.assert(values.len <= values_max);

    return core.shown(arena, kinds.list(), values);
}

/// Each value as `shown` gives it; a file (`lines`) changed against `base` with the lines it
/// changed marked in its box, the runs it left alone folded.
pub fn marked(
    arena: std.mem.Allocator,
    kinds: Kinds,
    mode: []const u8,
    base: []const Value,
    values: []const Value,
) ![]const Shown {
    std.debug.assert(mode.len > 0);

    return core.marked(arena, kinds.list(), mode, base, values);
}

/// One value as people see it, marked `same`, `added` or `removed`.
pub fn one(arena: std.mem.Allocator, kinds: Kinds, value: Value, mark: []const u8) !Shown {
    std.debug.assert(mark.len > 0);

    return core.one(arena, kinds.list(), value, mark);
}

/// What `after` changed against `before`, to read beside the value; none when nothing
/// changed, or when the value is new whole (all of it is in its box already).
pub fn changes(
    arena: std.mem.Allocator,
    mode: []const u8,
    before: []const Value,
    after: []const Value,
) ![]const Segment {
    return core.changes(arena, mode, before, after);
}

/// Whether two versions hold the same values, in the same order.
pub fn same(before: []const Value, after: []const Value) bool {
    std.debug.assert(before.len <= values_max);
    std.debug.assert(after.len <= values_max);

    if (before.len != after.len) {
        return false;
    }

    for (before, after) |left, right| {
        if (!std.mem.eql(u8, left.json, right.json)) {
            return false;
        }
    }

    return true;
}

/// Whether `list` holds a value with this JSON.
pub fn has(list: []const Value, json: []const u8) bool {
    std.debug.assert(json.len > 0);
    std.debug.assert(list.len <= values_max);

    for (list) |value| {
        if (std.mem.eql(u8, value.json, json)) {
            return true;
        }
    }

    return false;
}

/// The segments as a page's own item type.
pub fn segments_into(
    comptime Item: type,
    arena: std.mem.Allocator,
    list: []const Segment,
) ![]const Item {
    std.debug.assert(list.len <= values_max * 4);

    const items = try arena.alloc(Item, list.len);

    for (list, items) |segment, *item| {
        item.* = .{
            .text = segment.text,
            .mark = segment.mark,
        };
    }

    std.debug.assert(items.len == list.len);

    return items;
}

/// The values as a page's own item type (`CompareValue` as the page declares it).
pub fn into(comptime Item: type, arena: std.mem.Allocator, list: []const Shown) ![]const Item {
    std.debug.assert(list.len <= values_max);

    const items = try arena.alloc(Item, list.len);
    const SegmentItem = std.meta.Elem(@FieldType(Item, "segments"));
    const Icon = @FieldType(Item, "icon");

    for (list, items) |value, *item| {
        item.* = .{
            .json = value.json,
            .mark = value.mark,
            .card = value.card,
            .title = value.title,
            .type_label = value.type_label,
            .status = value.status,
            .tone = value.tone,
            .href = value.href,
            .segments = try segments_into(SegmentItem, arena, value.segments),
            .definition = value.definition,
            .icon = std.meta.stringToEnum(Icon, value.icon) orelse .link,
            .required = value.required,
            .summary = value.summary,
            .name = value.name,
            .details = value.details,
        };
    }

    std.debug.assert(items.len == list.len);

    return items;
}

/// A plugin's row as a version holds it (`sandboxed_plugins`' columns, the JSON ones as
/// text), and what it shows as.
pub const plugin = struct {
    /// Empty when the version has no such plugin.
    pub const Row = struct {
        manifest: []const u8 = "",
        granted: []const u8 = "[]",
        denied: []const u8 = "[]",
        grants: []const u8 = "[]",
        enabled: ?bool = null,
    };

    /// One JSON value per thing the row shows: the plugin, whether it runs, each request.
    pub const RowValues = struct {
        plugin: []const []const u8,
        enabled: []const []const u8,
        requests: []const []const u8,
    };

    pub fn values_of(arena: std.mem.Allocator, row: Row) !RowValues {
        std.debug.assert(row.granted.len > 0);

        return @import("../../adapters/admin/compare/plugin.zig").values_of(arena, row);
    }
};
