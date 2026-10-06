//! An installed plugin compared as its page shows it: the plugin (name, version, summary),
//! whether it runs, and what it asks to do, each request with its reason, its tier and where
//! it stands. Built from the plugin's row (its manifest and grants), never from its hash.
const std = @import("std");
const plugin_state = @import("../../../operations/plugin/state.zig");
const field = @import("field.zig");

const Shown = field.Shown;

/// A plugin's row as a version holds it, the JSON columns as text; empty when the version
/// has no such plugin.
pub const Row = struct {
    manifest: []const u8 = "",
    granted: []const u8 = "[]",
    denied: []const u8 = "[]",
    enabled: ?bool = null,
};

/// What a plugin's row shows as, one JSON value per thing: the plugin, whether it runs,
/// each request. A value's JSON is what `of` draws it from.
pub const RowValues = struct {
    plugin: []const []const u8,
    enabled: []const []const u8,
    requests: []const []const u8,
};

const requests_max: u32 = 256;

pub fn values_of(arena: std.mem.Allocator, row: Row) !RowValues {
    std.debug.assert(row.granted.len > 0 and row.denied.len > 0);

    if (row.manifest.len == 0) {
        return .{ .plugin = &.{}, .enabled = &.{}, .requests = &.{} };
    }

    const manifest = try plugin_state.parse_manifest(arena, row.manifest);
    const granted = try names_in(arena, row.granted);
    const denied = try names_in(arena, row.denied);
    const requests = try plugin_state.requests_of(arena, &manifest, granted, denied);
    const shown = try arena.alloc([]const u8, requests.len);

    std.debug.assert(requests.len <= requests_max);

    for (requests, shown) |request, *json| {
        json.* = try std.json.Stringify.valueAlloc(arena, .{
            .key = request.key,
            .sentence = request.sentence,
            .reason = request.reason,
            .tier = @tagName(request.tier),
            .state = @tagName(request.state),
        }, .{});
    }

    const plugin = try std.json.Stringify.valueAlloc(arena, .{
        .plugin = manifest.name,
        .version = manifest.version,
        .summary = manifest.summary,
    }, .{});
    const enabled: []const []const u8 = if (row.enabled) |on|
        try arena.dupe([]const u8, &.{if (on) "\"Yes\"" else "\"No\""})
    else
        &.{};

    return .{
        .plugin = try arena.dupe([]const u8, &.{plugin}),
        .enabled = enabled,
        .requests = shown,
    };
}

fn names_in(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    std.debug.assert(text.len > 0);

    const options: std.json.ParseOptions = .{ .allocate = .alloc_always };

    return std.json.parseFromSliceLeaky([]const []const u8, arena, text, options) catch {
        return error.Invalid;
    };
}

/// The value drawn as a definition card: a plugin, or a request it makes; null for anything
/// else.
pub fn of(arena: std.mem.Allocator, json: []const u8) !?Shown {
    std.debug.assert(json.len <= 1 << 20);

    if (json.len == 0 or json[0] != '{') {
        return null;
    }

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch {
        return null;
    };
    const object = parsed.object;

    if (text_in(object, "plugin")) |name| {
        return try plugin_card(arena, json, object, name);
    }

    const key = text_in(object, "key") orelse return null;
    const sentence = text_in(object, "sentence") orelse return null;
    const reason = text_in(object, "reason") orelse "";

    std.debug.assert(key.len > 0 and sentence.len > 0);

    return .{
        .json = json,
        .mark = "same",
        .card = false,
        .title = sentence,
        .definition = true,
        .icon = "lock",
        .summary = try std.fmt.allocPrint(arena, "{s} · {s}", .{
            try word_of(arena, text_in(object, "tier") orelse "low"),
            try word_of(arena, text_in(object, "state") orelse "pending"),
        }),
        .name = key,
        .details = if (reason.len == 0)
            &.{}
        else
            try arena.dupe([]const u8, &.{try std.fmt.allocPrint(arena, "“{s}”", .{reason})}),
    };
}

fn plugin_card(
    arena: std.mem.Allocator,
    json: []const u8,
    object: std.json.ObjectMap,
    name: []const u8,
) !Shown {
    std.debug.assert(name.len > 0);

    const version = text_in(object, "version") orelse "";
    const summary = text_in(object, "summary") orelse "";

    std.debug.assert(json.len > name.len);

    return .{
        .json = json,
        .mark = "same",
        .card = false,
        .title = name,
        .definition = true,
        .icon = "package",
        .summary = try std.fmt.allocPrint(arena, "Version {s}", .{version}),
        .name = name,
        .details = if (summary.len == 0) &.{} else try arena.dupe([]const u8, &.{summary}),
    };
}

fn text_in(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    std.debug.assert(key.len > 0);

    const value = object.get(key) orelse return null;

    return if (value == .string and value.string.len > 0) value.string else null;
}

/// `rolled_back` as `Rolled back`, `low` as `Low`.
fn word_of(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    std.debug.assert(text.len > 0);

    const word = try arena.dupe(u8, text);

    for (word) |*char| {
        if (char.* == '_') {
            char.* = ' ';
        }
    }

    word[0] = std.ascii.toUpper(word[0]);

    return word;
}

test "a request reads as its card, a plugin as its own" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const request =
        \\{"key":"users.names","sentence":"See the names of people","reason":"Greets them",
        \\"tier":"low","state":"granted"}
    ;
    const shown = (try of(arena, request)).?;
    const plugin = (try of(arena, "{\"plugin\":\"greeter\",\"version\":\"0.1.0\"}")).?;

    try std.testing.expectEqualStrings("Low · Granted", shown.summary);
    try std.testing.expectEqualStrings("users.names", shown.name);
    try std.testing.expectEqualStrings("Version 0.1.0", plugin.summary);
    try std.testing.expect(try of(arena, "{\"title\":\"x\"}") == null);
}
