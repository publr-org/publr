//! What still needs a plugin about to stop: every enabled plugin, installed or built in, that
//! names it in `depends_on`. Stopping it is refused while one is left running; the refusal
//! names them and the one command that stops them together. A plugin that only lists it in
//! `compatible_with` keeps running, its hooks into it silent.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const registry = @import("../../server/registry.zig");
const state = @import("state.zig");
const depends_on = @import("../../sdk/plugin/depends_on.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;

/// The most plugins one call stops together.
pub const together_max: u32 = 32;

pub const Running = struct { name: []const u8, depends_on: []const []const u8, built_in: bool };

/// Refused when a plugin outside `names` still needs one of them: `verb` is what was asked
/// (`disable`, `remove`), and the message says how to stop them all at once.
pub fn refuse_left_behind(ctx: *Ctx, names: []const []const u8, verb: []const u8) Error!void {
    std.debug.assert(names.len <= together_max);
    std.debug.assert(verb.len > 0);

    const why = try left_behind(ctx.arena, try running_of(ctx), names, verb) orelse return;

    return ctx.fail(.{ .name = "DependedOn", .status = 409, .message = why });
}

/// Why `names` cannot stop while `running` does, or null when nothing running needs them.
pub fn left_behind(
    arena: std.mem.Allocator,
    running: []const Running,
    names: []const []const u8,
    verb: []const u8,
) Error!?[]const u8 {
    std.debug.assert(names.len <= together_max);
    std.debug.assert(verb.len > 0);

    var needed: std.ArrayList([]const u8) = .empty;

    for (names) |target| {
        for (running) |plugin| {
            const outside = !listed(names, plugin.name) and !listed(needed.items, plugin.name);

            if (!outside or !needs(plugin, target)) {
                continue;
            }

            if (plugin.built_in) {
                const text = std.fmt.allocPrint(arena, "the built-in plugin {s} depends on " ++
                    "{s}, so it cannot stop", .{ plugin.name, target });

                return text catch error.OutOfMemory;
            }

            needed.append(arena, plugin.name) catch return error.OutOfMemory;
        }
    }

    if (needed.items.len == 0) {
        return null;
    }

    const together = try closure(arena, running, needed.items, names);

    return try message(arena, needed.items, names, together, verb);
}

/// Everything that has to stop with `names`: the dependents found, theirs in turn, and the
/// plugins asked for, dependents first.
fn closure(
    arena: std.mem.Allocator,
    running: []const Running,
    needed: []const []const u8,
    names: []const []const u8,
) Error![]const []const u8 {
    std.debug.assert(needed.len > 0);

    var all: std.ArrayList([]const u8) = .empty;

    all.appendSlice(arena, needed) catch return error.OutOfMemory;

    var index: u32 = 0;

    while (index < all.items.len and all.items.len <= running.len) : (index += 1) {
        for (running) |plugin| {
            const fresh = !listed(all.items, plugin.name) and !listed(names, plugin.name);

            if (fresh and !plugin.built_in and needs(plugin, all.items[index])) {
                all.append(arena, plugin.name) catch return error.OutOfMemory;
            }
        }
    }

    all.appendSlice(arena, names) catch return error.OutOfMemory;

    return all.items;
}

fn message(
    arena: std.mem.Allocator,
    needed: []const []const u8,
    names: []const []const u8,
    together: []const []const u8,
    verb: []const u8,
) Error![]const u8 {
    std.debug.assert(needed.len > 0 and names.len > 0);

    const who = std.mem.join(arena, ", ", needed) catch return error.OutOfMemory;
    const what = std.mem.join(arena, ", ", names) catch return error.OutOfMemory;
    const all = std.mem.join(arena, ",", together) catch return error.OutOfMemory;
    const verb_word = if (needed.len == 1) "depends" else "depend";
    const text = if (std.mem.eql(u8, verb, "disable"))
        std.fmt.allocPrint(arena, "{s} {s} on {s}. To disable them together: " ++
            "publr plugin disable --names {s}", .{ who, verb_word, what, all })
    else
        std.fmt.allocPrint(arena, "{s} {s} on {s}. Disable them first: " ++
            "publr plugin disable --names {s}", .{ who, verb_word, what, all });

    return text catch error.OutOfMemory;
}

/// The plugins running now: every built-in one, and the installed ones enabled.
fn running_of(ctx: *Ctx) Error![]const Running {
    std.debug.assert(ctx.now_ms >= 0);

    var running: std.ArrayList(Running) = .empty;

    inline for (registry.native_plugins.all) |Plugin| {
        running.append(ctx.arena, .{
            .name = Plugin.manifest.name,
            .depends_on = comptime depends_on.of(Plugin),
            .built_in = true,
        }) catch return error.OutOfMemory;
    }

    for (try store.sandboxed_plugins.list(ctx.db, ctx.arena)) |row| {
        if (row.enabled) {
            const manifest = try state.parse_manifest(ctx.arena, row.manifest);

            running.append(ctx.arena, .{
                .name = manifest.name,
                .depends_on = manifest.depends_on,
                .built_in = false,
            }) catch return error.OutOfMemory;
        }
    }

    return running.items;
}

fn needs(plugin: Running, target: []const u8) bool {
    std.debug.assert(target.len > 0);

    for (plugin.depends_on) |text| {
        if (text.len > 0 and std.mem.eql(u8, depends_on.parse(text).name, target)) {
            return true;
        }
    }

    return false;
}

fn listed(names: []const []const u8, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (names) |each| {
        if (std.mem.eql(u8, each, name)) {
            return true;
        }
    }

    return false;
}

test "dependents: a chain, a disabled one, an optional one and a built-in one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const running = [_]Running{
        .{ .name = "inventory", .depends_on = &.{}, .built_in = false },
        .{ .name = "cart", .depends_on = &.{"inventory@^1"}, .built_in = false },
        .{ .name = "wishlist", .depends_on = &.{"cart"}, .built_in = false },
        .{ .name = "reviews", .depends_on = &.{}, .built_in = false },
    };

    const alone = (try left_behind(arena, &running, &.{"inventory"}, "disable")).?;
    try std.testing.expectEqualStrings("cart depends on inventory. To disable them " ++
        "together: publr plugin disable --names cart,wishlist,inventory", alone);

    const all = [_][]const u8{ "wishlist", "cart", "inventory" };
    try std.testing.expect(try left_behind(arena, &running, &all, "disable") == null);
    try std.testing.expect(try left_behind(arena, &running, &.{"reviews"}, "remove") == null);

    const removing = (try left_behind(arena, &running, &.{"cart"}, "remove")).?;
    try std.testing.expect(std.mem.indexOf(u8, removing, "Disable them first") != null);

    const built_in = [_]Running{
        .{ .name = "inventory", .depends_on = &.{}, .built_in = false },
        .{ .name = "shop", .depends_on = &.{"inventory"}, .built_in = true },
    };
    const stuck = (try left_behind(arena, &built_in, &.{"inventory"}, "disable")).?;
    try std.testing.expect(std.mem.indexOf(u8, stuck, "built-in plugin shop") != null);
}
