//! An installed plugin's interactive components, as its module carries them in
//! `publr.interactive` (`{ "components": [...], "render", "browser", "classes" }`): read as it
//! loads, for the apps that reach it to place them and draw them with their render as
//! JavaScript.
const std = @import("std");
const wasm = @import("publr_wasm");
const sdk = @import("../../sdk.zig");
const plugin_manifest = @import("../../sdk/plugin/manifest.zig");

const Interactive = sdk.sandboxed_plugins.Interactive;

/// What the section holds, its components as JSON.
const Carried = struct {
    components: std.json.Value,
    render: []const u8,
    browser: []const u8,
    classes: []const u8,
};

/// `plugin`'s interactive components from its module `bytes`, appended to `into`; none
/// when it carries none. A section that does not read is refused: a plugin build made it.
pub fn read(
    arena: std.mem.Allocator,
    plugin: []const u8,
    bytes: []const u8,
    into: *std.ArrayList(Interactive),
) !void {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(bytes.len > 0);

    const text = (wasm.section.find(bytes, plugin_manifest.interactive_section_name) catch {
        return error.InvalidInteractive;
    }) orelse return;
    const carried = std.json.parseFromSliceLeaky(Carried, arena, text, .{
        .allocate = .alloc_always,
    }) catch return error.InvalidInteractive;

    if (carried.components != .array or carried.render.len == 0) {
        return error.InvalidInteractive;
    }

    try into.append(arena, .{
        .plugin = try arena.dupe(u8, plugin),
        .components = try std.json.Stringify.valueAlloc(arena, carried.components, .{}),
        .render = carried.render,
        .browser = carried.browser,
        .classes = carried.classes,
    });
}

/// The section's text for a build's four files (`components.json` as it is).
pub fn section(
    arena: std.mem.Allocator,
    components: []const u8,
    render: []const u8,
    browser: []const u8,
    classes: []const u8,
) ![]const u8 {
    std.debug.assert(components.len > 0);
    std.debug.assert(render.len > 0);

    const listed = try std.json.parseFromSliceLeaky(std.json.Value, arena, components, .{});

    return std.json.Stringify.valueAlloc(arena, Carried{
        .components = listed,
        .render = render,
        .browser = browser,
        .classes = classes,
    }, .{});
}

test "a section reads back as the plugin's interactive components" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = try section(arena, "[{\"name\":\"Box\"}]", "globalThis.x = 1;", "", "p-4\n");
    var module: std.Io.Writer.Allocating = .init(arena);

    try module.writer.writeAll(&.{ 0, 'a', 's', 'm', 1, 0, 0, 0 });
    try wasm.section.write(&module.writer, plugin_manifest.interactive_section_name, text);

    var found: std.ArrayList(Interactive) = .empty;

    try read(arena, "boxes", module.written(), &found);
    try std.testing.expectEqual(@as(usize, 1), found.items.len);
    try std.testing.expectEqualStrings("[{\"name\":\"Box\"}]", found.items[0].components);
    try std.testing.expectEqualStrings("p-4\n", found.items[0].classes);

    var none: std.ArrayList(Interactive) = .empty;

    try read(arena, "boxes", &.{ 0, 'a', 's', 'm', 1, 0, 0, 0 }, &none);
    try std.testing.expectEqual(@as(usize, 0), none.items.len);
}
