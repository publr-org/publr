//! Reading a document in a combination. Each field gives the value of the best key it holds
//! for the combination asked, under its plain name; the `@` keys go. Only the keys a field
//! actually holds are looked at, so a site with many dimensions costs no more than one: a key
//! fits when each dimension it names is asked for, at its code or a shorter prefix of it, and
//! of the fitting keys the best is the one most specific in the highest priority dimension,
//! then the next. `(pl, b)` thus prefers `pl,b`, then `pl`, then `b`, then the main value.

const std = @import("std");
const dimension = @import("../dimension.zig");
const field = @import("../field.zig");

const Def = field.Def;
const Value = std.json.Value;
const Pair = dimension.Pair;
const order_max = dimension.order_max;
const dimensions_max = dimension.dimensions_max;

/// A combination asked for, ranked: for each dimension in priority order, its code's prefixes.
pub const Ranking = struct {
    dimensions: [dimensions_max][]const u8 = undefined,
    chains: [dimensions_max][order_max][]const u8 = undefined,
    lengths: [dimensions_max]u32 = undefined,
    len: u32 = 0,

    /// `wanted`, highest priority first; a dimension at its main value is left out.
    pub fn of(wanted: []const Pair) Ranking {
        std.debug.assert(wanted.len <= dimensions_max);

        var ranking: Ranking = .{};

        for (wanted) |pair| {
            if (pair.code.len == 0) {
                continue;
            }

            const at = ranking.len;
            const chain = dimension.order(pair.code, &ranking.chains[at]);

            ranking.dimensions[at] = pair.dimension;
            // The main value is not a prefix: a key never names it.
            ranking.lengths[at] = @intCast(chain.len - 1);
            ranking.len += 1;
        }

        return ranking;
    }

    /// How specific `text` (a key's combination) is for each ranked dimension, in priority
    /// order: the prefix depth it names (0 for the code itself), or the chain's length for a
    /// dimension it leaves at the main value. Null when it does not fit.
    fn score(ranking: *const Ranking, text: []const u8, out: *[dimensions_max]u32) bool {
        std.debug.assert(ranking.len <= dimensions_max);

        const combination = dimension.parse(text) orelse return false;

        for (0..ranking.len) |index| {
            out[index] = ranking.lengths[index];
        }

        for (combination.slice()) |pair| {
            const index = ranking.index_of(pair.dimension) orelse return false;
            const chain = ranking.chains[index][0..ranking.lengths[index]];
            const depth = for (chain, 0..) |code, at| {
                if (std.mem.eql(u8, code, pair.code)) {
                    break at;
                }
            } else return false;

            out[index] = @intCast(depth);
        }

        return true;
    }

    fn index_of(ranking: *const Ranking, name: []const u8) ?u32 {
        std.debug.assert(name.len > 0);

        for (0..ranking.len) |index| {
            if (std.mem.eql(u8, ranking.dimensions[index], name)) {
                return @intCast(index);
            }
        }

        return null;
    }
};

/// The value `object` holds for `def` that a read in `ranking` shows: the best fitting key's,
/// else the main value; `skip` names a key passed over (a combination's own, for the value it
/// falls back to). Null when the field holds nothing that fits.
pub fn best(
    def: *const Def,
    object: std.json.ObjectMap,
    ranking: *const Ranking,
    skip: []const u8,
) ?Value {
    std.debug.assert(def.name.len > 0);
    std.debug.assert(ranking.len <= dimensions_max);

    var chosen: ?Value = null;
    var chosen_score: [dimensions_max]u32 = undefined;
    var score: [dimensions_max]u32 = undefined;
    var entries = object.iterator();

    while (entries.next()) |entry| {
        const key = dimension.split(entry.key_ptr.*);
        const value = entry.value_ptr.*;

        if (value == .null or key.combination.len == 0 or std.mem.eql(u8, entry.key_ptr.*, skip)) {
            continue;
        }

        const ours = std.mem.eql(u8, key.name, def.name) and
            dimension.fits(def.dimensions, key.combination);

        if (!ours or !ranking.score(key.combination, &score)) {
            continue;
        }

        if (chosen == null or less(score[0..ranking.len], chosen_score[0..ranking.len])) {
            chosen = value;
            chosen_score = score;
        }
    }

    if (chosen) |found| {
        return found;
    }

    const main = object.get(def.name) orelse return null;

    return if (main == .null or std.mem.eql(u8, def.name, skip)) null else main;
}

fn less(left: []const u32, right: []const u32) bool {
    std.debug.assert(left.len == right.len);

    for (left, right) |one, other| {
        if (one != other) {
            return one < other;
        }
    }

    return false;
}

/// The document as read in `wanted` (each dimension at a code, highest priority first; an
/// empty code or none at all reads the main values). Groups and repeaters are read in the
/// same combination all the way down. A value kept empty on purpose (`""`) counts as given.
pub fn resolve(
    arena: std.mem.Allocator,
    fields: []const Def,
    document: Value,
    wanted: []const Pair,
) error{OutOfMemory}!Value {
    std.debug.assert(fields.len <= field.fields_max);
    std.debug.assert(wanted.len <= dimensions_max);

    if (document != .object) {
        return document;
    }

    const ranking: Ranking = .of(wanted);

    return resolve_object(arena, fields, document.object, &ranking);
}

fn resolve_object(
    arena: std.mem.Allocator,
    fields: []const Def,
    object: std.json.ObjectMap,
    ranking: *const Ranking,
) error{OutOfMemory}!Value {
    std.debug.assert(fields.len <= field.fields_max);
    std.debug.assert(ranking.len <= dimensions_max);

    var out: std.json.ObjectMap = .empty;
    var entries = object.iterator();

    // What the type does not describe passes through as it is, but no `@` key does.
    while (entries.next()) |entry| {
        const key = dimension.split(entry.key_ptr.*);

        if (key.combination.len > 0 or field_named(fields, key.name) != null) {
            continue;
        }

        try out.put(arena, entry.key_ptr.*, entry.value_ptr.*);
    }

    for (fields) |*def| {
        const picked = pick(def, object, ranking) orelse continue;

        try out.put(arena, def.name, try resolve_value(arena, def, picked, ranking));
    }

    return .{
        .object = out,
    };
}

fn pick(def: *const Def, object: std.json.ObjectMap, ranking: *const Ranking) ?Value {
    std.debug.assert(def.name.len > 0);
    std.debug.assert(ranking.len <= dimensions_max);

    if (def.dimensions.len == 0) {
        return object.get(def.name);
    }

    return best(def, object, ranking, "");
}

fn resolve_value(
    arena: std.mem.Allocator,
    def: *const Def,
    value: Value,
    ranking: *const Ranking,
) error{OutOfMemory}!Value {
    std.debug.assert(def.name.len > 0);
    std.debug.assert(ranking.len <= dimensions_max);

    if (def.fields.len == 0 or !field.is_container(def.kind)) {
        return value;
    }

    if (field.is_group(def.kind)) {
        if (value != .object) {
            return value;
        }

        return resolve_object(arena, def.fields, value.object, ranking);
    }

    if (value != .array) {
        return value;
    }

    var items = std.json.Array.init(arena);

    for (value.array.items) |item| {
        const resolved = if (item == .object)
            try resolve_object(arena, def.fields, item.object, ranking)
        else
            item;

        try items.append(resolved);
    }

    return .{
        .array = items,
    };
}

fn field_named(fields: []const Def, name: []const u8) ?*const Def {
    std.debug.assert(fields.len <= field.fields_max);

    for (fields) |*def| {
        if (std.mem.eql(u8, def.name, name)) {
            return def;
        }
    }

    return null;
}

/// Every dimension at a code a document holds a value in anywhere, each once, in the order
/// first met.
pub fn held_in(
    arena: std.mem.Allocator,
    fields: []const Def,
    document: Value,
) error{OutOfMemory}![]const Pair {
    std.debug.assert(fields.len <= field.fields_max);

    var found: std.ArrayList(Pair) = .empty;

    try collect(arena, fields, document, &found);

    return found.items;
}

fn collect(
    arena: std.mem.Allocator,
    fields: []const Def,
    value: Value,
    found: *std.ArrayList(Pair),
) error{OutOfMemory}!void {
    std.debug.assert(fields.len <= field.fields_max);

    switch (value) {
        .array => |array| for (array.items) |item| {
            try collect(arena, fields, item, found);
        },
        .object => |object| {
            var entries = object.iterator();

            while (entries.next()) |entry| {
                const key = dimension.split(entry.key_ptr.*);
                const def = field_named(fields, key.name) orelse continue;

                if (key.combination.len > 0 and dimension.fits(def.dimensions, key.combination)) {
                    try note(arena, key.combination, found);
                }

                if (field.is_container(def.kind)) {
                    try collect(arena, def.fields, entry.value_ptr.*, found);
                }
            }
        },
        else => {},
    }
}

fn note(arena: std.mem.Allocator, text: []const u8, found: *std.ArrayList(Pair)) !void {
    std.debug.assert(text.len > 0);

    const combination = dimension.parse(text) orelse return;

    for (combination.slice()) |pair| {
        if (!contains(found.items, pair)) {
            try found.append(arena, pair);
        }
    }
}

fn contains(pairs: []const Pair, pair: Pair) bool {
    std.debug.assert(pair.code.len > 0);

    for (pairs) |known| {
        const same = std.mem.eql(u8, known.dimension, pair.dimension) and
            std.mem.eql(u8, known.code, pair.code);

        if (same) {
            return true;
        }
    }

    return false;
}

test "best: only the keys a field holds, the highest priority dimension most specific" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const def: Def = .{
        .name = "title",
        .label = "Title",
        .kind = "string",
        .dimensions = &.{ "language", "variation", "pricing" },
    };
    const text =
        \\{"title":"Main","title@language=en":"En","title@variation=b":"B",
        \\"title@language=en,variation=b":"En B","title@pricing=demo":"Demo"}
    ;
    const document = try std.json.parseFromSliceLeaky(Value, arena, text, .{});
    const object = document.object;
    const british_b: Ranking = .of(&.{
        .{
            .dimension = "language",
            .code = "en-gb",
        },
        .{
            .dimension = "variation",
            .code = "b",
        },
        .{
            .dimension = "pricing",
            .code = "",
        },
    });

    try std.testing.expectEqualStrings("En B", best(&def, object, &british_b, "").?.string);
    const passed_over = best(&def, object, &british_b, "title@language=en,variation=b");

    try std.testing.expectEqualStrings("En", passed_over.?.string);

    const german_b: Ranking = .of(&.{
        .{
            .dimension = "language",
            .code = "de",
        },
        .{
            .dimension = "variation",
            .code = "b",
        },
    });

    try std.testing.expectEqualStrings("B", best(&def, object, &german_b, "").?.string);

    // Forty more dimensions asked for change nothing: only the keys held are compared.
    var many: [dimensions_max]Pair = undefined;
    const names = [_][]const u8{ "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10" };

    many[0] = .{
        .dimension = "language",
        .code = "de",
    };

    for (names, 1..) |name, at| {
        many[at] = .{
            .dimension = name,
            .code = "x",
        };
    }

    const crowded: Ranking = .of(many[0 .. names.len + 1]);

    try std.testing.expectEqualStrings("Main", best(&def, object, &crowded, "").?.string);
    // A key naming a dimension the read leaves at its main value does not fit.
    try std.testing.expect(best(&def, object, &.of(&.{}), "title") == null);
}

test "resolve: each field in the combination, else its fallback, nested ones too" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const both = &[_][]const u8{ "language", "variation" };
    const items = [_]Def{.{
        .name = "heading",
        .label = "Heading",
        .kind = "string",
        .dimensions = &.{"language"},
    }};
    const fields = [_]Def{
        .{
            .name = "name",
            .label = "Name",
            .kind = "string",
            .dimensions = both,
        },
        .{
            .name = "note",
            .label = "Note",
            .kind = "string",
            .dimensions = &.{dimension.every},
        },
        .{
            .name = "price",
            .label = "Price",
            .kind = "integer",
        },
        .{
            .name = "sections",
            .label = "Sections",
            .kind = "repeater",
            .fields = &items,
        },
    };
    const text =
        \\{"name":"Mug","name@language=en":"Mug (en)","name@language=pl":"Kubek",
        \\"name@variation=b":"Mug!","note":"Glazed","note@language=pl":"","price":4900,
        \\"sections":[{"heading":"One","heading@language=pl":"Jeden"},{"heading":"Two"}],
        \\"_extra":1}
    ;
    const document = try std.json.parseFromSliceLeaky(Value, arena, text, .{});
    const polish_b = try resolve(arena, &fields, document, &.{
        .{
            .dimension = "language",
            .code = "pl",
        },
        .{
            .dimension = "variation",
            .code = "b",
        },
    });

    try std.testing.expectEqualStrings("Kubek", polish_b.object.get("name").?.string);
    try std.testing.expectEqualStrings("", polish_b.object.get("note").?.string);
    try std.testing.expectEqual(@as(i64, 4900), polish_b.object.get("price").?.integer);
    try std.testing.expect(polish_b.object.get("name@language=pl") == null);
    try std.testing.expect(polish_b.object.get("_extra") != null);

    const sections = polish_b.object.get("sections").?.array.items;

    try std.testing.expectEqualStrings("Jeden", sections[0].object.get("heading").?.string);
    try std.testing.expectEqualStrings("Two", sections[1].object.get("heading").?.string);

    const german_b = try resolve(arena, &fields, document, &.{
        .{
            .dimension = "language",
            .code = "de",
        },
        .{
            .dimension = "variation",
            .code = "b",
        },
    });

    try std.testing.expectEqualStrings("Mug!", german_b.object.get("name").?.string);

    const british = try resolve(arena, &fields, document, &.{
        .{
            .dimension = "language",
            .code = "en-gb",
        },
    });

    try std.testing.expectEqualStrings("Mug (en)", british.object.get("name").?.string);
    try std.testing.expectEqualStrings("Glazed", british.object.get("note").?.string);

    const main = try resolve(arena, &fields, document, &.{});

    try std.testing.expectEqualStrings("Mug", main.object.get("name").?.string);

    const held = try held_in(arena, &fields, document);

    try std.testing.expectEqual(@as(usize, 3), held.len);
}
