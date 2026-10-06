//! A field of a content type compared as the type's field list shows it: its kind's icon,
//! its label and what matters about it (`Reference (many) to lesson`), the rest in words.
const std = @import("std");
const registry = @import("../../../server/registry.zig");
const kinds = @import("../../../model/kinds.zig");
const model_field = @import("../../../model/field.zig");

/// A value ready to draw, as `CompareValue` declares it.
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

pub const Segment = struct { text: []const u8, mark: []const u8 };

const said = [_][]const u8{ "name", "label", "kind", "many", "required", "options", "fields" };
const options_said = [_][]const u8{ "to", "taxonomy", "choices" };
const settings_max: u32 = 256;

/// The value as a field's row; null for a value that is not a field's definition.
pub fn of(arena: std.mem.Allocator, json: []const u8) !?Shown {
    std.debug.assert(json.len <= 1 << 20);

    if (json.len == 0 or json[0] != '{') {
        return null;
    }

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch {
        return null;
    };
    const name = text_in(parsed.object, "name") orelse return null;
    const kind_id = text_in(parsed.object, "kind") orelse return null;
    const options = parsed.object.get("options") orelse std.json.Value{ .null = {} };

    std.debug.assert(name.len > 0 and kind_id.len > 0);

    return .{
        .json = json,
        .mark = "same",
        .card = false,
        .title = text_in(parsed.object, "label") orelse name,
        .definition = true,
        .icon = kinds.lookup(registry.Kinds.all, kind_id).icon,
        .required = flag_in(parsed.object, "required"),
        .summary = try summary_of(arena, parsed.object, kind_id, options),
        .name = name,
        .details = try details_of(arena, parsed.object, options),
    };
}

/// The kind and what matters about it, as the field list says it.
fn summary_of(
    arena: std.mem.Allocator,
    definition: std.json.ObjectMap,
    kind_id: []const u8,
    options: std.json.Value,
) ![]const u8 {
    std.debug.assert(kind_id.len > 0);

    const kind = kinds.lookup(registry.Kinds.all, kind_id);
    var summary: std.ArrayList(u8) = .empty;

    try summary.appendSlice(arena, kind.label);

    if (flag_in(definition, "many")) {
        try summary.appendSlice(arena, " (many)");
    }

    if (kind.has.target) {
        const targets = try list_in(arena, options, "to");

        try summary.print(arena, " to {s}", .{if (targets.len == 0) "any type" else targets});
    } else if (kind.has.taxonomy) {
        const taxonomy = if (options == .object) text_in(options.object, "taxonomy") else null;

        try summary.print(arena, " of {s}", .{taxonomy orelse ""});
    } else if (kind.has.choices) {
        try summary.print(arena, ", {d} choices", .{count_in(options, "choices")});
    } else if (model_field.is_container(kind_id)) {
        const fields = count_in(.{ .object = definition }, "fields");

        try summary.print(arena, ", {d} fields", .{fields});
    }

    std.debug.assert(summary.items.len >= kind.label.len);

    return summary.items;
}

/// The settings beyond what the row says, one line each: `Help: Shown under it`.
fn details_of(
    arena: std.mem.Allocator,
    definition: std.json.ObjectMap,
    options: std.json.Value,
) ![]const []const u8 {
    std.debug.assert(definition.count() <= settings_max);

    var lines: std.ArrayList([]const u8) = .empty;

    try settings_lines(arena, &lines, definition, &said);

    if (options == .object) {
        try settings_lines(arena, &lines, options.object, &options_said);
    }

    std.debug.assert(lines.items.len <= settings_max * 2);

    return lines.items;
}

fn settings_lines(
    arena: std.mem.Allocator,
    lines: *std.ArrayList([]const u8),
    settings: std.json.ObjectMap,
    skip: []const []const u8,
) !void {
    std.debug.assert(skip.len > 0);
    std.debug.assert(settings.count() <= settings_max);

    var iterator = settings.iterator();

    while (iterator.next()) |entry| {
        if (one_of(entry.key_ptr.*, skip)) {
            continue;
        }

        const line = try line_of(arena, entry.key_ptr.*, entry.value_ptr.*) orelse continue;

        try lines.append(arena, line);
    }
}

/// One setting in words; null when it says nothing (empty, off).
fn line_of(arena: std.mem.Allocator, key: []const u8, value: std.json.Value) !?[]const u8 {
    std.debug.assert(key.len > 0);

    const said_key = try humanized(arena, key);
    const said_value: []const u8 = switch (value) {
        .null => return null,
        .bool => |on| if (on) return said_key else return null,
        .string => |text| if (text.len == 0) return null else text,
        .array => |list| if (list.items.len == 0) return null else try list_in(arena, value, ""),
        .object => |map| if (map.count() == 0)
            return null
        else
            try std.json.Stringify.valueAlloc(arena, value, .{}),
        else => try std.json.Stringify.valueAlloc(arena, value, .{}),
    };

    std.debug.assert(said_key.len == key.len);

    return try std.fmt.allocPrint(arena, "{s}: {s}", .{ said_key, said_value });
}

fn text_in(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    std.debug.assert(key.len > 0);

    const value = object.get(key) orelse return null;

    return if (value == .string and value.string.len > 0) value.string else null;
}

fn flag_in(object: std.json.ObjectMap, key: []const u8) bool {
    std.debug.assert(key.len > 0);

    const value = object.get(key) orelse return false;

    return value == .bool and value.bool;
}

fn count_in(value: std.json.Value, key: []const u8) u32 {
    std.debug.assert(key.len > 0);

    if (value != .object) {
        return 0;
    }

    const list = value.object.get(key) orelse return 0;

    return if (list == .array) @intCast(list.array.items.len) else 0;
}

/// A list's words joined (`post, page`): the list itself, or the one under `key`.
fn list_in(arena: std.mem.Allocator, value: std.json.Value, key: []const u8) ![]const u8 {
    std.debug.assert(key.len <= 64);

    const nested = if (value == .object and key.len > 0) value.object.get(key) else null;
    const list = if (key.len == 0) value else nested orelse return "";

    if (list != .array) {
        return "";
    }

    var text: std.ArrayList(u8) = .empty;

    for (list.array.items) |item| {
        if (text.items.len > 0) {
            try text.appendSlice(arena, ", ");
        }

        if (item == .string) {
            try text.appendSlice(arena, item.string);
        } else {
            try text.appendSlice(arena, try std.json.Stringify.valueAlloc(arena, item, .{}));
        }
    }

    return text.items;
}

fn one_of(text: []const u8, options: []const []const u8) bool {
    std.debug.assert(options.len > 0);

    for (options) |option| {
        if (std.mem.eql(u8, text, option)) {
            return true;
        }
    }

    return false;
}

/// `help_text` as `Help text`.
fn humanized(arena: std.mem.Allocator, key: []const u8) ![]const u8 {
    std.debug.assert(key.len > 0);

    const text = try arena.dupe(u8, key);

    for (text) |*char| {
        if (char.* == '_') {
            char.* = ' ';
        }
    }

    text[0] = std.ascii.toUpper(text[0]);

    return text;
}

test "a field's definition reads as its row, anything else is not one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const json =
        \\{"name":"chapters","label":"Chapters","kind":"reference","many":true,
        \\"options":{"to":["chapter"]},"help":"Shown below"}
    ;
    const shown = (try of(arena, json)).?;

    try std.testing.expectEqualStrings("Chapters", shown.title);
    try std.testing.expectEqualStrings("Reference (many) to chapter", shown.summary);
    try std.testing.expectEqualStrings("Help: Shown below", shown.details[0]);
    try std.testing.expect(try of(arena, "\"text\"") == null);
    try std.testing.expect(try of(arena, "{\"title\":\"x\"}") == null);
}
