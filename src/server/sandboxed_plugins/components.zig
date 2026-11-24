//! An installed plugin's site components (`components/<Name>.publr`), as its module carries
//! them in `publr.components` (`[{ "name", "text" }]`): read as it loads, for the apps to
//! import as `plugin:<plugin>/<Name>` and to draw in a contract owner's provider slot.
const std = @import("std");
const wasm = @import("publr_wasm");
const sdk = @import("../../sdk.zig");
const plugin_manifest = @import("../../sdk/plugin/manifest.zig");

const Component = sdk.sandboxed_plugins.Component;

/// The most components one plugin brings.
pub const components_max: u32 = 64;
/// The longest name a component has.
pub const name_len_max: u32 = 64;

pub const Carried = struct {
    name: []const u8,
    text: []const u8,
};

/// `plugin`'s components from its module `bytes`, appended to `into`; none when it carries
/// none. A section that does not read is refused: the module was not made by a plugin build.
pub fn read(
    arena: std.mem.Allocator,
    plugin: []const u8,
    bytes: []const u8,
    into: *std.ArrayList(Component),
) !void {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(bytes.len > 0);

    const text = (wasm.section.find(bytes, plugin_manifest.components_section_name) catch {
        return error.InvalidComponents;
    }) orelse return;
    const carried = std.json.parseFromSliceLeaky([]const Carried, arena, text, .{}) catch {
        return error.InvalidComponents;
    };

    if (carried.len > components_max) {
        return error.InvalidComponents;
    }

    for (carried) |one| {
        if (!valid_name(one.name)) {
            return error.InvalidComponents;
        }

        try into.append(arena, .{
            .plugin = try arena.dupe(u8, plugin),
            .name = one.name,
            .text = one.text,
        });
    }
}

/// A component's name: a capital letter, then letters and digits (`LockerPicker`), and
/// `.dynamic` after it for one drawn for each visitor (`Account.dynamic`).
pub fn valid_name(name: []const u8) bool {
    std.debug.assert(name_len_max > 0);

    const stem = if (std.mem.endsWith(u8, name, ".dynamic"))
        name[0 .. name.len - ".dynamic".len]
    else
        name;

    if (stem.len == 0 or name.len > name_len_max or !std.ascii.isUpper(stem[0])) {
        return false;
    }

    for (stem) |char| {
        if (!std.ascii.isAlphanumeric(char)) {
            return false;
        }
    }

    return true;
}

test "a component's name is a capitalised word" {
    try std.testing.expect(valid_name("LockerPicker"));
    try std.testing.expect(!valid_name("lockerPicker"));
    try std.testing.expect(!valid_name("Locker-Picker"));
    try std.testing.expect(!valid_name(""));
    try std.testing.expect(valid_name("Account.dynamic"));
    try std.testing.expect(!valid_name(".dynamic"));
}
