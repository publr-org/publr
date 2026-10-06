//! Two versions side by side, as `CompareField` and `CompareValues` draw them: each value
//! as people see it, and what one version changed against the other.
const std = @import("std");
const registry = @import("../../server/registry.zig");
const diff = @import("../../model/diff.zig");
const field = @import("compare/field.zig");
pub const plugin = @import("compare/plugin.zig");

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

pub const Segment = field.Segment;

/// A value ready to draw: the fields `CompareValue` has.
pub const Shown = field.Shown;

const values_max: u32 = 4096;

/// Each value as people see it, unmarked.
pub fn shown(arena: std.mem.Allocator, values: []const Value) ![]const Shown {
    std.debug.assert(values.len <= values_max);

    const found = try arena.alloc(Shown, values.len);

    for (values, found) |value, *item| {
        item.* = try one(arena, value, "same");
    }

    std.debug.assert(found.len == values.len);

    return found;
}

/// One value as people see it, marked `same`, `added` or `removed`.
pub fn one(arena: std.mem.Allocator, value: Value, mark: []const u8) !Shown {
    std.debug.assert(mark.len > 0);
    std.debug.assert(value.json.len > 0 or value.text.len == 0);

    const segments = try arena.dupe(Segment, &.{.{ .text = value.text, .mark = mark }});

    const definition = try field.of(arena, value.json) orelse try plugin.of(arena, value.json);

    if (definition) |found| {
        var card = found;

        card.mark = mark;
        card.segments = segments;

        return card;
    }

    if (value.card_title.len == 0) {
        return .{
            .json = value.json,
            .mark = mark,
            .card = false,
            .title = value.text,
            .segments = segments,
        };
    }

    const status = status_of(value.card_status);

    return .{
        .json = value.json,
        .mark = mark,
        .card = true,
        .title = value.card_title,
        .type_label = value.card_type,
        .status = status.label,
        .tone = status.tone,
        .href = value.card_href,
        .segments = segments,
    };
}

/// What `after` changed against `before`, to read beside the value: a text word by word, a
/// field's definition line by line, a list or a card item by item, what it dropped struck
/// through. None when nothing changed, or when the value is new whole (all of it is in its
/// box already).
pub fn changes(
    arena: std.mem.Allocator,
    mode: []const u8,
    before: []const Value,
    after: []const Value,
) ![]const Segment {
    std.debug.assert(before.len <= values_max);
    std.debug.assert(after.len <= values_max);

    if (same(before, after) or before.len == 0) {
        return &.{};
    }

    if (after.len == 1 and is_object(after[0].json) and is_object(before[0].json)) {
        return lines_changed(arena, before[0].text, after[0].text);
    }

    if (std.mem.eql(u8, mode, "text") and after.len <= 1 and before.len == 1) {
        return words_changed(arena, before[0].text, if (after.len == 1) after[0].text else "");
    }

    return items_changed(arena, before, after);
}

fn words_changed(arena: std.mem.Allocator, before: []const u8, after: []const u8) ![]const Segment {
    std.debug.assert(before.len > 0 or after.len > 0);

    var found: std.ArrayList(Segment) = .empty;

    for (try diff.words(arena, before, after)) |segment| {
        try found.append(arena, .{ .text = segment.text, .mark = @tagName(segment.mark) });
    }

    std.debug.assert(found.items.len > 0);

    return found.items;
}

fn items_changed(
    arena: std.mem.Allocator,
    before: []const Value,
    after: []const Value,
) ![]const Segment {
    std.debug.assert(!same(before, after));

    var found: std.ArrayList(Segment) = .empty;

    for (after) |value| {
        try item_segment(arena, &found, value, if (has(before, value.json)) "same" else "added");
    }

    for (before) |value| {
        if (!has(after, value.json)) {
            try item_segment(arena, &found, value, "removed");
        }
    }

    std.debug.assert(found.items.len > 0);

    return found.items;
}

/// What changed in a field's definition, as the lines that say it (`Label: Title`): the
/// lines it dropped struck through, the lines it has new, unchanged ones left out.
fn lines_changed(arena: std.mem.Allocator, before: []const u8, after: []const u8) ![]const Segment {
    std.debug.assert(!std.mem.eql(u8, before, after) or before.len == 0);

    var found: std.ArrayList(Segment) = .empty;
    var old_lines = std.mem.splitScalar(u8, before, '\n');

    while (old_lines.next()) |line| {
        if (line.len > 0 and !has_line(after, line)) {
            try line_segment(arena, &found, line, "removed");
        }
    }

    var new_lines = std.mem.splitScalar(u8, after, '\n');

    while (new_lines.next()) |line| {
        if (line.len > 0 and !has_line(before, line)) {
            try line_segment(arena, &found, line, "added");
        }
    }

    std.debug.assert(found.items.len <= (before.len + after.len) * 2 + 2);

    return found.items;
}

fn has_line(text: []const u8, wanted: []const u8) bool {
    std.debug.assert(wanted.len > 0);

    var lines = std.mem.splitScalar(u8, text, '\n');

    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, wanted)) {
            return true;
        }
    }

    return false;
}

fn line_segment(
    arena: std.mem.Allocator,
    found: *std.ArrayList(Segment),
    line: []const u8,
    mark: []const u8,
) !void {
    std.debug.assert(line.len > 0);
    std.debug.assert(mark.len > 0);

    if (found.items.len > 0) {
        try found.append(arena, .{ .text = ", ", .mark = "same" });
    }

    try found.append(arena, .{ .text = line, .mark = mark });
}

fn item_segment(
    arena: std.mem.Allocator,
    found: *std.ArrayList(Segment),
    value: Value,
    mark: []const u8,
) !void {
    std.debug.assert(mark.len > 0);
    std.debug.assert(value.json.len > 0);

    if (found.items.len > 0) {
        try found.append(arena, .{ .text = ", ", .mark = "same" });
    }

    const text = if (value.card_title.len > 0) value.card_title else value.text;

    try found.append(arena, .{ .text = text, .mark = mark });
}

fn is_object(json: []const u8) bool {
    return json.len > 0 and json[0] == '{';
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

const StatusShown = struct { label: []const u8, tone: []const u8 };

fn status_of(id: []const u8) StatusShown {
    std.debug.assert(id.len <= 64);

    const known = registry.Statuses.find(id) orelse {
        return .{ .label = id, .tone = "neutral" };
    };
    const tone = switch (known.color) {
        .neutral => "neutral",
        .info => "accent",
        .success => "success",
        .warning => "warning",
        .danger => "error",
    };

    std.debug.assert(known.label.len > 0);

    return .{ .label = known.label, .tone = tone };
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
        item.* = .{ .text = segment.text, .mark = segment.mark };
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

test "a text changed shows the words, a value new whole shows nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = [_]Value{.{ .json = "\"Hello world\"", .text = "Hello world" }};
    const after = [_]Value{.{ .json = "\"Hello there\"", .text = "Hello there" }};

    try std.testing.expect((try changes(arena, "text", &before, &after)).len > 0);
    try std.testing.expectEqual(0, (try changes(arena, "text", &.{}, &after)).len);
    try std.testing.expectEqual(0, (try changes(arena, "text", &after, &after)).len);
}
