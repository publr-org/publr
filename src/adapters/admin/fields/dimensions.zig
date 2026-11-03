//! A type's fields as the record form draws and reads them on a site with a dimension of
//! several values (languages): each field varying by it is followed by one field per
//! other value, named `name@language=pl`, so it is drawn, posted and read back like any
//! field. The editor shows one combination at a time; an empty value shows its fallback's
//! text as its placeholder.
const std = @import("std");
const model = @import("../../../model.zig");

const Def = model.field.Def;
const Pair = model.dimension.Pair;
const Value = std.json.Value;

pub const Error = error{OutOfMemory};

/// A dimension of the site's as the form needs it: its name and its codes other than the
/// main one, highest priority first.
pub const SiteDimension = struct {
    name: []const u8,
    codes: []const []const u8,
    /// The top-level fields it shows on (an A/B test's, on one record); null: every field
    /// varying by it.
    only: ?[]const []const u8 = null,
};

/// The most combinations one field's form draws.
pub const combinations_max: u32 = 256;

/// `fields` with each varied field's values after it: one per combination of the dimensions
/// that field varies by (each at its main value or one of its codes, at most
/// `key_pairs_max` named), so a site with many dimensions costs a field only its own. A
/// group or repeater that is not varied as a whole has its varied fields expanded inside;
/// one varied as a whole is a structure of its own per combination, inside which nothing
/// more varies. `document` gives each combination its placeholder (its fallback's value), at
/// the top level and in groups.
pub fn expanded(
    arena: std.mem.Allocator,
    fields: []const Def,
    site: []const SiteDimension,
    document: ?Value,
) Error![]const Def {
    std.debug.assert(fields.len <= model.field.fields_max);
    std.debug.assert(site.len <= model.dimension.dimensions_max);

    if (site.len == 0) {
        return fields;
    }

    var out: std.ArrayList(Def) = .empty;

    for (fields) |def| {
        const current = if (document) |doc| object_get(doc, def.name) else null;
        var own = def;

        const varied = def.dimensions.len > 0;

        if (model.field.is_container(def.kind) and !varied) {
            const inner = if (model.field.is_group(def.kind)) current else null;

            own.fields = try expanded(arena, def.fields, site, inner);
        }

        try out.append(arena, own);

        if (!varied) {
            continue;
        }

        for (try combinations_of(arena, def, site)) |other| {
            const shown = if (document) |doc| fallback_of(def, doc, other) else null;

            try out.append(arena, try clone_of(arena, def, other, shown));
        }
    }

    return out.items;
}

/// Every combination of the dimensions `def` varies by, but the main one, highest priority
/// first within each.
fn combinations_of(
    arena: std.mem.Allocator,
    def: Def,
    site: []const SiteDimension,
) Error![]const []const Pair {
    std.debug.assert(def.dimensions.len > 0);
    std.debug.assert(site.len <= model.dimension.dimensions_max);

    var found: std.ArrayList([]const Pair) = .empty;

    try found.append(arena, &.{});

    for (site) |dimension| {
        if (!model.dimension.varies_by(def.dimensions, dimension.name)) {
            continue;
        }

        if (dimension.only) |only| {
            if (!model.dimension.lists(only, def.name)) {
                continue;
            }
        }

        var grown: std.ArrayList([]const Pair) = .empty;

        for (found.items) |before| {
            try grown.append(arena, before);

            if (before.len == model.dimension.key_pairs_max) {
                continue;
            }

            for (dimension.codes) |code| {
                if (grown.items.len >= combinations_max) {
                    break;
                }

                try grown.append(arena, try std.mem.concat(arena, Pair, &.{ before, &.{.{
                    .dimension = dimension.name,
                    .code = code,
                }} }));
            }
        }

        found = grown;
    }

    std.debug.assert(found.items.len >= 1);

    return found.items[1..];
}

fn clone_of(arena: std.mem.Allocator, def: Def, other: []const Pair, main: ?Value) Error!Def {
    std.debug.assert(def.dimensions.len > 0);
    std.debug.assert(other.len > 0);

    var clone = def;

    clone.name = try model.dimension.key_of(arena, def.name, other);
    clone.validation.required = false;
    clone.validation.unique = false;
    clone.locked = false;
    clone.dimensions = &.{};
    clone.default = "";
    clone.validation.items_min = null;

    if (main) |value| {
        if (value == .string and value.string.len > 0) {
            clone.options.placeholder = value.string;
        }
    }

    return clone;
}

/// What a read in `other` shows when the field holds nothing there: the best value it holds
/// for that combination, the combination's own key passed over.
fn fallback_of(def: Def, document: Value, other: []const Pair) ?Value {
    std.debug.assert(other.len > 0);
    std.debug.assert(def.name.len > 0);

    if (document != .object) {
        return null;
    }

    const resolve = model.dimension.resolve;
    const ranking: resolve.Ranking = .of(other);
    var buffer: [512]u8 = undefined;
    const own = model.dimension.key_into(&buffer, def.name, other) orelse return null;

    return resolve.best(&def, document.object, &ranking, own);
}

fn object_get(value: Value, name: []const u8) ?Value {
    std.debug.assert(name.len > 0);

    return switch (value) {
        .object => |object| object.get(name),
        else => null,
    };
}

test "a varied field is followed by its combinations; a group's varied fields inside it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const seo = [_]Def{
        .{
            .name = "title",
            .label = "Title",
            .kind = "string",
            .dimensions = &.{"language"},
        },
    };
    const fields = [_]Def{
        .{
            .validation = .{
                .required = true,
            },
            .name = "name",
            .label = "Name",
            .kind = "string",
            .dimensions = &.{"language"},
        },
        .{
            .name = "price",
            .label = "Price",
            .kind = "integer",
        },
        .{
            .name = "seo",
            .label = "SEO",
            .kind = "group",
            .fields = &seo,
        },
    };
    const document = try std.json.parseFromSliceLeaky(Value, arena, "{\"name\":\"Mug\"}", .{});
    const site = [_]SiteDimension{
        .{
            .name = "language",
            .codes = &.{ "pl", "de" },
        },
        .{
            .name = "variation",
            .codes = &.{"b"},
        },
    };
    const out = try expanded(arena, &fields, &site, document);

    try std.testing.expectEqual(@as(usize, 5), out.len);
    try std.testing.expectEqualStrings("name@language=pl", out[1].name);
    try std.testing.expect(!out[1].validation.required);
    try std.testing.expectEqualStrings("Mug", out[1].options.placeholder);
    try std.testing.expectEqualStrings("name@language=de", out[2].name);
    try std.testing.expectEqualStrings("title@language=pl", out[4].fields[1].name);
    try std.testing.expectEqual(fields.len, (try expanded(arena, &fields, &.{}, null)).len);
}
