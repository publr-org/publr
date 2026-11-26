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

/// What this Publr has, by name, for `missing`.
pub const Known = struct {
    /// The namespaces of core's and the built-in plugins' operations.
    namespaces: []const []const u8,
    operations: []const []const u8,
    /// The namespaces core's events and mods are in, beside the operations'.
    item_namespaces: []const []const u8 = &.{},
    events: []const []const u8 = &.{},
    mods: []const []const u8 = &.{},
    /// How the names of the mods core applies to every record type end (`.title`).
    mod_endings: []const []const u8 = &.{},
};

/// What `uses` names in a namespace this Publr knows that it lacks, as `uses` names it: an
/// operation called (`call:`), an event emitted or hooked (`emit:`, `hook:`, either an
/// event or an operation, which is an event too), a mod read or modified (`mod:`). What
/// another plugin owns is checked with it; a transition event (`…transitioned`) follows its
/// record type.
pub fn missing(
    arena: std.mem.Allocator,
    uses: []const []const u8,
    known: Known,
) error{OutOfMemory}![]const []const u8 {
    std.debug.assert(uses.len <= uses_max);

    var found: std.ArrayList([]const u8) = .empty;

    for (uses) |used| {
        const colon = std.mem.indexOfScalar(u8, used, ':') orelse continue;
        const kind = used[0..colon];
        const name = used[colon + 1 ..];
        const dot = std.mem.indexOfScalar(u8, name, '.') orelse continue;

        if (dot == 0) {
            continue;
        }

        const owned = contains(known.namespaces, name[0..dot]) or
            contains(known.item_namespaces, name[0..dot]);
        const lacking = if (std.mem.eql(u8, kind, "call"))
            contains(known.namespaces, name[0..dot]) and !contains(known.operations, name)
        else if (std.mem.eql(u8, kind, "emit") or std.mem.eql(u8, kind, "hook"))
            owned and !contains(known.operations, name) and !contains(known.events, name) and
                !std.mem.endsWith(u8, name, "transitioned")
        else if (std.mem.eql(u8, kind, "mod"))
            owned and !contains(known.mods, name) and !ends_any(name, known.mod_endings)
        else
            false;

        if (lacking) {
            try found.append(arena, used);
        }
    }

    std.debug.assert(found.items.len <= uses.len);

    return found.items;
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

fn ends_any(name: []const u8, endings: []const []const u8) bool {
    std.debug.assert(name.len > 0);

    for (endings) |ending| {
        if (std.mem.endsWith(u8, name, ending)) {
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

test "only what a namespace this Publr knows lacks is missing, whatever kind of use" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const uses = [_][]const u8{
        "call:money.texts",     "call:money.gone",    "call:languages.get",
        "emit:messaging.email", "emit:messaging.fax", "hook:record.save",
        "hook:role.vanished",   "hook:orders.placed", "hook:shop.product_transitioned",
        "mod:media.base",       "mod:media.gone",     "mod:user.title",
        "mod:orders.price",     "host:publr_call",    "call:.nameless",
    };
    const known: Known = .{
        .namespaces = &.{ "money", "media", "record", "user" },
        .operations = &.{ "money.texts", "money.format", "record.save" },
        .item_namespaces = &.{ "messaging", "role" },
        .events = &.{ "messaging.email", "role.created" },
        .mods = &.{"media.base"},
        .mod_endings = &.{".title"},
    };
    const found = try missing(arena_state.allocator(), &uses, known);

    try std.testing.expectEqual(@as(usize, 4), found.len);
    try std.testing.expectEqualStrings("call:money.gone", found[0]);
    try std.testing.expectEqualStrings("emit:messaging.fax", found[1]);
    try std.testing.expectEqualStrings("hook:role.vanished", found[2]);
    try std.testing.expectEqualStrings("mod:media.gone", found[3]);
}
