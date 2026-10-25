//! Reading a document in a combination. Each field gives the value of the first key in its
//! fallback that holds one, under its plain name; the `@` keys go. A field's fallback runs
//! over the dimensions it varies by, in the order asked (highest priority first): each
//! through its code's prefixes to its main value, the last dimension's first, as a number
//! counts down, so `(pl, b)` reads `(pl, b)`, `(pl, main)`, `(main, b)`, then the main value.

const std = @import("std");
const dimension = @import("../dimension.zig");
const field = @import("../field.zig");

const Def = field.Def;
const Value = std.json.Value;
const Pair = dimension.Pair;
const order_max = dimension.order_max;
const dimensions_max = dimension.dimensions_max;

/// The keys one field is read through, most specific first.
pub const Fallback = struct {
    name: []const u8,
    dimensions: [dimensions_max][]const u8 = undefined,
    chains: [dimensions_max][order_max][]const u8 = undefined,
    lengths: [dimensions_max]u32 = undefined,
    digits: [dimensions_max]u32 = undefined,
    len: u32 = 0,
    done: bool = false,

    /// For a field named `name` varying by `varies`, read in `wanted`: its dimensions the
    /// read names, in its order; one it does not name is at its main value.
    pub fn of(name: []const u8, varies: []const []const u8, wanted: []const Pair) Fallback {
        std.debug.assert(name.len > 0);
        std.debug.assert(wanted.len <= dimensions_max);

        var fallback: Fallback = .{
            .name = name,
        };

        for (wanted) |pair| {
            if (pair.code.len == 0 or !dimension.varies_by(varies, pair.dimension)) {
                continue;
            }

            const at = fallback.len;
            const chain = dimension.order(pair.code, &fallback.chains[at]);

            fallback.dimensions[at] = pair.dimension;
            fallback.lengths[at] = @intCast(chain.len);
            fallback.digits[at] = 0;
            fallback.len += 1;
        }

        return fallback;
    }

    /// The next key, written into `buffer`; null once the main value's has been given.
    pub fn next(fallback: *Fallback, buffer: []u8) ?[]const u8 {
        std.debug.assert(fallback.len <= dimensions_max);
        std.debug.assert(buffer.len > fallback.name.len);

        if (fallback.done) {
            return null;
        }

        var pairs: [dimensions_max]Pair = undefined;

        for (0..fallback.len) |index| {
            pairs[index] = .{
                .dimension = fallback.dimensions[index],
                .code = fallback.chains[index][fallback.digits[index]],
            };
        }

        const key = dimension.key_into(buffer, fallback.name, pairs[0..fallback.len]);

        fallback.advance();

        return key orelse fallback.name;
    }

    fn advance(fallback: *Fallback) void {
        std.debug.assert(fallback.len <= dimensions_max);
        std.debug.assert(!fallback.done);

        var at = fallback.len;

        while (at > 0) {
            at -= 1;
            fallback.digits[at] += 1;

            if (fallback.digits[at] < fallback.lengths[at]) {
                return;
            }

            fallback.digits[at] = 0;
        }

        fallback.done = true;
    }
};

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

    return resolve_object(arena, fields, document.object, wanted);
}

fn resolve_object(
    arena: std.mem.Allocator,
    fields: []const Def,
    object: std.json.ObjectMap,
    wanted: []const Pair,
) error{OutOfMemory}!Value {
    std.debug.assert(fields.len <= field.fields_max);
    std.debug.assert(wanted.len <= dimensions_max);

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
        const picked = pick(def, object, wanted) orelse continue;

        try out.put(arena, def.name, try resolve_value(arena, def, picked, wanted));
    }

    return .{
        .object = out,
    };
}

fn pick(def: *const Def, object: std.json.ObjectMap, wanted: []const Pair) ?Value {
    std.debug.assert(def.name.len > 0);
    std.debug.assert(wanted.len <= dimensions_max);

    if (def.dimensions.len == 0) {
        return object.get(def.name);
    }

    var fallback: Fallback = .of(def.name, def.dimensions, wanted);
    var buffer: [field.name_len_max + 4 * (dimension.name_len_max + 18)]u8 = undefined;

    while (fallback.next(&buffer)) |key| {
        if (object.get(key)) |value| {
            if (value != .null) {
                return value;
            }
        }
    }

    return null;
}

fn resolve_value(
    arena: std.mem.Allocator,
    def: *const Def,
    value: Value,
    wanted: []const Pair,
) error{OutOfMemory}!Value {
    std.debug.assert(def.name.len > 0);
    std.debug.assert(wanted.len <= dimensions_max);

    if (def.fields.len == 0 or !field.is_container(def.kind)) {
        return value;
    }

    if (field.is_group(def.kind)) {
        if (value != .object) {
            return value;
        }

        return resolve_object(arena, def.fields, value.object, wanted);
    }

    if (value != .array) {
        return value;
    }

    var items = std.json.Array.init(arena);

    for (value.array.items) |item| {
        const resolved = if (item == .object)
            try resolve_object(arena, def.fields, item.object, wanted)
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

test "fallback: the last dimension counts down first, each through its prefixes" {
    var fallback: Fallback = .of("title", &.{ "language", "variation" }, &.{
        .{
            .dimension = "language",
            .code = "en-gb",
        },
        .{
            .dimension = "variation",
            .code = "b",
        },
    });
    var buffer: [256]u8 = undefined;
    const expected = [_][]const u8{
        "title@language=en-gb,variation=b",
        "title@language=en-gb",
        "title@language=en,variation=b",
        "title@language=en",
        "title@variation=b",
        "title",
    };

    for (expected) |key| {
        try std.testing.expectEqualStrings(key, fallback.next(&buffer).?);
    }

    try std.testing.expect(fallback.next(&buffer) == null);

    // A dimension the field does not vary by is left out of its keys.
    var one: Fallback = .of("title", &.{"language"}, &.{
        .{
            .dimension = "language",
            .code = "pl",
        },
        .{
            .dimension = "variation",
            .code = "b",
        },
    });

    try std.testing.expectEqualStrings("title@language=pl", one.next(&buffer).?);
    try std.testing.expectEqualStrings("title", one.next(&buffer).?);
    try std.testing.expect(one.next(&buffer) == null);
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
