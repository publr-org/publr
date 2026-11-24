//! Plugins enabled together start in the order they need each other: each after every plugin
//! among them it names in `depends_on` (a provider after its contract's owner), so asking for
//! all of them at once works in any order they are named.
const std = @import("std");
const depends_on = @import("../../sdk/plugin/depends_on.zig");

pub const together_max = @import("dependents.zig").together_max;

pub const Named = struct {
    name: []const u8,
    depends_on: []const []const u8,
};

/// `plugins` in an order where each follows those among them it depends on; a cycle keeps
/// the order given for the rest, for their own checks to refuse.
pub fn ordered(arena: std.mem.Allocator, plugins: []const Named) ![]const []const u8 {
    std.debug.assert(plugins.len <= together_max);

    var out: std.ArrayList([]const u8) = .empty;
    var placed: [together_max]bool = @splat(false);
    var round: u32 = 0;

    while (out.items.len < plugins.len and round <= plugins.len) : (round += 1) {
        var moved = false;

        for (plugins, 0..) |plugin, index| {
            if (placed[index] or !ready(plugins, &placed, plugin)) {
                continue;
            }

            placed[index] = true;
            moved = true;
            try out.append(arena, plugin.name);
        }

        if (!moved) {
            break;
        }
    }

    for (plugins, 0..) |plugin, index| {
        if (!placed[index]) {
            try out.append(arena, plugin.name);
        }
    }

    std.debug.assert(out.items.len == plugins.len);

    return out.items;
}

/// Whether every plugin among `plugins` that `plugin` depends on is placed already.
fn ready(plugins: []const Named, placed: *const [together_max]bool, plugin: Named) bool {
    std.debug.assert(plugin.name.len > 0);

    for (plugins, 0..) |other, index| {
        const needed = !std.mem.eql(u8, other.name, plugin.name) and
            depends_on.names(plugin.depends_on, other.name);

        if (needed and !placed[index]) {
            return false;
        }
    }

    return true;
}

test "plugins enabled together start after what they need, in any order named" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const plugins = [_]Named{
        .{
            .name = "bank_transfer",
            .depends_on = &.{"payments@^0.1"},
        },
        .{
            .name = "payments",
            .depends_on = &.{"orders"},
        },
        .{
            .name = "orders",
            .depends_on = &.{},
        },
    };
    const order = try ordered(arena_state.allocator(), &plugins);

    try std.testing.expectEqualStrings("orders", order[0]);
    try std.testing.expectEqualStrings("payments", order[1]);
    try std.testing.expectEqualStrings("bank_transfer", order[2]);
}
