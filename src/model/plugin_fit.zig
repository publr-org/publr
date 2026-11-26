//! Whether an installed plugin fits this Publr, from what its manifest says: the Publr it
//! was built with (`minimum_publr`) and what it uses (`uses`: `call:money.texts`, …).
const std = @import("std");

pub const uses_max: u32 = 4096;

/// Whether a plugin built with `minimum` runs on `running`: the same release or a later one.
/// A plugin that names no minimum (built before plugins named one) is not judged here.
pub fn new_enough(minimum: []const u8, running: []const u8) bool {
    std.debug.assert(running.len > 0);

    if (minimum.len == 0) {
        return true;
    }

    const needed = std.SemanticVersion.parse(minimum) catch return false;
    const here = std.SemanticVersion.parse(running) catch return false;

    return here.order(needed) != .lt;
}

/// The operations `uses` calls (`call:<name>`) that belong to a namespace in `namespaces`
/// (core's and the built-in plugins') and are not in `operations`: what this Publr removed,
/// or never had. Calls into other namespaces are an installed plugin's, checked with it.
pub fn missing_calls(
    arena: std.mem.Allocator,
    uses: []const []const u8,
    namespaces: []const []const u8,
    operations: []const []const u8,
) error{OutOfMemory}![]const []const u8 {
    std.debug.assert(uses.len <= uses_max);

    var missing: std.ArrayList([]const u8) = .empty;

    for (uses) |used| {
        if (!std.mem.startsWith(u8, used, "call:")) {
            continue;
        }

        const name = used["call:".len..];
        const dot = std.mem.indexOfScalar(u8, name, '.') orelse continue;

        if (dot == 0) {
            continue;
        }

        if (contains(namespaces, name[0..dot]) and !contains(operations, name)) {
            try missing.append(arena, name);
        }
    }

    std.debug.assert(missing.items.len <= uses.len);

    return missing.items;
}

fn contains(names: []const []const u8, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (names) |one| {
        if (std.mem.eql(u8, one, name)) {
            return true;
        }
    }

    return false;
}

test "a plugin runs on the Publr it was built with and every later one, never an earlier one" {
    try std.testing.expect(new_enough("0.8.2", "0.8.2"));
    try std.testing.expect(new_enough("0.8.2", "0.8.3"));
    try std.testing.expect(new_enough("0.8.2", "1.0.0"));
    try std.testing.expect(!new_enough("0.8.2", "0.8.1"));
    try std.testing.expect(!new_enough("0.9.0", "0.8.9"));
    try std.testing.expect(new_enough("", "0.8.1"));
    try std.testing.expect(!new_enough("nope", "0.8.1"));
}

test "only a call into a namespace this Publr knows, to an operation it lacks, is missing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const uses = [_][]const u8{
        "call:money.texts",
        "call:money.gone",
        "call:languages.get",
        "emit:orders.placed",
        "mod:media.base",
        "host:publr_call",
        "call:.nameless",
    };
    const namespaces = [_][]const u8{ "money", "media" };
    const operations = [_][]const u8{ "money.texts", "money.format" };
    const missing = try missing_calls(arena_state.allocator(), &uses, &namespaces, &operations);

    try std.testing.expectEqual(@as(usize, 1), missing.len);
    try std.testing.expectEqualStrings("money.gone", missing[0]);
}
