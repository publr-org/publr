//! A set of changes to a document: each top-level key it changes (`title`,
//! `title@language=pl`) and its new value, null for a key emptied. What a scheduled publish
//! puts live: only the keys its edits changed, laid over the live document as it is then, so
//! what changed live meanwhile stays.
const std = @import("std");

const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

pub const Error = error{OutOfMemory};

/// The keys `after` holds differently from `before`, each with its value in `after`, null
/// where `after` has none.
pub fn between(arena: std.mem.Allocator, before: Value, after: Value) Error!ObjectMap {
    std.debug.assert(before == .object);
    std.debug.assert(after == .object);

    var changes: ObjectMap = .empty;

    for (after.object.keys(), after.object.values()) |key, value| {
        if (!try same(arena, before.object.get(key), value)) {
            try changes.put(arena, key, value);
        }
    }

    for (before.object.keys()) |key| {
        if (after.object.get(key) == null and !try same(arena, before.object.get(key), null)) {
            try changes.put(arena, key, .null);
        }
    }

    return changes;
}

/// `document` with `changes` laid over it: each key set to its value, or dropped for null.
pub fn applied(arena: std.mem.Allocator, document: Value, changes: ObjectMap) Error!Value {
    std.debug.assert(document == .object);
    std.debug.assert(changes.count() <= 64 << 10);

    var out = try document.object.clone(arena);

    for (changes.keys(), changes.values()) |key, value| {
        if (value == .null) {
            _ = out.orderedRemove(key);
        } else {
            try out.put(arena, key, value);
        }
    }

    return .{
        .object = out,
    };
}

/// Edits parked on a document (`parked`) after `changes` went live over `live`: each key the
/// edits left as it was live takes the change too; a key they changed keeps their value.
pub fn carried(
    arena: std.mem.Allocator,
    parked: Value,
    live: Value,
    changes: ObjectMap,
) Error!Value {
    std.debug.assert(parked == .object);
    std.debug.assert(live == .object);

    var kept: ObjectMap = .empty;

    for (changes.keys(), changes.values()) |key, value| {
        if (try same(arena, parked.object.get(key), live.object.get(key))) {
            try kept.put(arena, key, value);
        }
    }

    return applied(arena, parked, kept);
}

/// Whether two values read the same; a missing one reads as null.
fn same(arena: std.mem.Allocator, left: ?Value, right: ?Value) Error!bool {
    const first = left orelse Value.null;
    const second = right orelse Value.null;

    if (first == .null or second == .null) {
        return first == .null and second == .null;
    }

    const first_text = try std.json.Stringify.valueAlloc(arena, first, .{});
    const second_text = try std.json.Stringify.valueAlloc(arena, second, .{});

    std.debug.assert(first_text.len > 0 and second_text.len > 0);

    return std.mem.eql(u8, first_text, second_text);
}

test "a change set: between two documents, laid over another, carried into parked edits" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parse = struct {
        fn of(allocator: std.mem.Allocator, text: []const u8) !Value {
            return std.json.parseFromSliceLeaky(Value, allocator, text, .{});
        }
    }.of;
    const live = try parse(arena, "{\"title\":\"Mug\",\"body\":\"Sturdy\",\"note\":\"x\"}");
    const deal = try parse(arena, "{\"title\":\"Deal\",\"body\":\"Sturdy\"}");
    const changes = try between(arena, live, deal);

    try std.testing.expectEqual(2, changes.count());
    try std.testing.expectEqualStrings("Deal", changes.get("title").?.string);
    try std.testing.expect(changes.get("note").? == .null);

    // Live meanwhile: the body fixed; the deal leaves it.
    const later = try parse(arena, "{\"title\":\"Mug\",\"body\":\"Sturdier\",\"note\":\"x\"}");
    const published = try applied(arena, later, changes);

    try std.testing.expectEqualStrings("Deal", published.object.get("title").?.string);
    try std.testing.expectEqualStrings("Sturdier", published.object.get("body").?.string);
    try std.testing.expect(published.object.get("note") == null);

    // Someone's parked edits: their own title stays, the note they left goes as the deal says.
    const parked = try parse(arena, "{\"title\":\"Mine\",\"body\":\"Sturdier\",\"note\":\"x\"}");
    const kept = try carried(arena, parked, later, changes);

    try std.testing.expectEqualStrings("Mine", kept.object.get("title").?.string);
    try std.testing.expect(kept.object.get("note") == null);
}
