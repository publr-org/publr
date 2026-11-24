//! What a plugin keeps for itself and nobody edits: carts, reservations, stock movements,
//! logs. Never content: no statuses, drafts, revisions or search. A plugin declares each
//! kind it keeps as a collection: the fields it may be found by, and whether its records,
//! once written, never change.

const std = @import("std");
const plugin_contracts = @import("plugin_contracts.zig");
const field_model = @import("field.zig");

pub const kind_len_max: u32 = 64;
pub const field_len_max: u32 = 64;
pub const value_len_max: u32 = 512;
pub const indexed_max: u32 = 8;
pub const collections_max: u32 = 32;
pub const document_bytes_max: u32 = 64 << 10;

/// How long a record is kept: `after_days` past its creation or its last change. Core clears
/// what has expired as new records of the collection are written, with no trash step.
pub const Expires = struct {
    after_days: u32,
    from: From = .updated,

    pub const From = enum { created, updated };
};

pub const Collection = struct {
    /// The collection's name, the plugin's own: `movement`, `cart`.
    kind: []const u8,
    /// The top-level fields records are found by (`find`, `find_one`); text, integers and
    /// booleans only.
    indexed: []const []const u8 = &.{},
    /// Written once, never changed or deleted: a ledger.
    append_only: bool = false,
    /// Records meant to vanish (visitor carts, one-time codes); null for kept ones.
    expires: ?Expires = null,
    /// Kept for the whole project, the same whichever app the call comes through: stock
    /// two shops sell from. Otherwise each app's records are its own: a visitor's cart.
    shared: bool = false,
    /// Each top-level field with its kind, from the record's Zig type: what another plugin's
    /// `publr.remote.record` on it is checked against.
    fields: []const plugin_contracts.ProvidedField = &.{},
    /// The top-level fields with rules, checked on every write as content's are: bounds and
    /// shapes (`.validation`), `.unique` among the collection's records (an idempotency key:
    /// a transfer's id), a provider field naming a provider of its contract.
    rules: []const field_model.Def = &.{},
    /// The top-level fields the plugin works out (`.virtual = .{ .computed = fn }`): stored
    /// with the record, worked out again when anything they read has changed. Never
    /// indexed: an index would answer by a value not yet worked out again.
    computed: []const []const u8 = &.{},
};

/// The most computed fields one collection has.
pub const computed_max: u32 = 8;

/// Why a plugin's collections cannot be declared, or null.
pub fn problem(collections: []const Collection) ?[]const u8 {
    std.debug.assert(kind_len_max > 0);

    if (collections.len > collections_max) {
        return "a plugin declares at most 32 internal record collections";
    }

    for (collections, 0..) |collection, index| {
        if (!valid_name(collection.kind, kind_len_max)) {
            return "a collection's kind is [a-z][a-z0-9_]*, up to 64 characters";
        }

        for (collections[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.kind, collection.kind)) {
                return "two collections share a kind";
            }
        }

        if (indexed_problem(collection.indexed)) |message| {
            return message;
        }

        if (rules_problem(collection)) |message| {
            return message;
        }

        if (computed_problem(collection)) |message| {
            return message;
        }
    }

    return null;
}

fn indexed_problem(indexed: []const []const u8) ?[]const u8 {
    std.debug.assert(indexed_max > 0);

    if (indexed.len > indexed_max) {
        return "a collection indexes at most 8 fields";
    }

    for (indexed, 0..) |field, index| {
        if (!valid_name(field, field_len_max)) {
            return "an indexed field is [a-z][a-z0-9_]*, up to 64 characters";
        }

        for (indexed[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier, field)) {
                return "a collection indexes a field twice";
            }
        }
    }

    return null;
}

/// A unique field is found by its value: indexed, one text or whole number.
fn rules_problem(collection: Collection) ?[]const u8 {
    std.debug.assert(collection.kind.len > 0);

    if (collection.rules.len > field_model.fields_max) {
        return "a collection has at most as many fields with rules as a type";
    }

    for (collection.rules) |rule| {
        // Found by it, a record would tell its value to whoever may not read it.
        if (rule.visibility.hidden() and indexes(collection, rule.name)) {
            return "a field only some may read is never indexed";
        }

        if (!rule.validation.unique) {
            continue;
        }

        if (!indexes(collection, rule.name)) {
            return "a unique field of an internal record is indexed";
        }

        // A reference is kept as its record's id: one text like any other.
        const kinds = [_][]const u8{
            "string",
            "email",
            "url",
            "integer",
            "decimal",
            "reference",
            "user",
            "ledger_account",
            "ledger_transfer",
        };
        const one_value = for (kinds) |kind| {
            if (std.mem.eql(u8, rule.kind, kind)) {
                break true;
            }
        } else false;

        if (rule.many or !one_value) {
            return "only a single text, whole number or reference field of an internal record " ++
                "is unique";
        }
    }

    return null;
}

/// A computed field is named once, is one of the record's fields, and is never indexed.
fn computed_problem(collection: Collection) ?[]const u8 {
    std.debug.assert(collection.kind.len > 0);
    std.debug.assert(computed_max > 0);

    if (collection.computed.len > computed_max) {
        return "a collection has at most 8 computed fields";
    }

    for (collection.computed, 0..) |field, index| {
        if (!valid_name(field, field_len_max)) {
            return "a computed field is [a-z][a-z0-9_]*, up to 64 characters";
        }

        for (collection.computed[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier, field)) {
                return "a collection names a computed field twice";
            }
        }

        if (indexes(collection, field)) {
            return "a computed field is never indexed: it would be found by a value not " ++
                "yet worked out again";
        }
    }

    return null;
}

pub fn computes(collection: Collection, field: []const u8) bool {
    std.debug.assert(collection.kind.len > 0);
    std.debug.assert(field.len > 0);

    for (collection.computed) |computed| {
        if (std.mem.eql(u8, computed, field)) {
            return true;
        }
    }

    return false;
}

pub fn find(collections: []const Collection, kind: []const u8) ?Collection {
    std.debug.assert(collections.len <= collections_max);
    std.debug.assert(kind.len > 0);

    for (collections) |collection| {
        if (std.mem.eql(u8, collection.kind, kind)) {
            return collection;
        }
    }

    return null;
}

pub fn indexes(collection: Collection, field: []const u8) bool {
    std.debug.assert(collection.kind.len > 0);
    std.debug.assert(field.len > 0);

    for (collection.indexed) |indexed| {
        if (std.mem.eql(u8, indexed, field)) {
            return true;
        }
    }

    return false;
}

/// The text an indexed value is found by: text as it is, integers in decimal, booleans as
/// `true`/`false`. Null for anything else (absent, null, a number with a fraction, a list,
/// an object): such a value is not indexed.
pub fn indexed_text(
    arena: std.mem.Allocator,
    value: std.json.Value,
) error{OutOfMemory}!?[]const u8 {
    std.debug.assert(value_len_max > 0);

    const text: []const u8 = switch (value) {
        .string => |string| string,
        .integer => |integer| try std.fmt.allocPrint(arena, "{d}", .{integer}),
        .bool => |flag| if (flag) "true" else "false",
        else => return null,
    };

    if (text.len > value_len_max) {
        return null;
    }

    return text;
}

pub fn valid_name(name: []const u8, len_max: u32) bool {
    std.debug.assert(len_max > 0);

    if (name.len == 0 or name.len > len_max or !std.ascii.isLower(name[0])) {
        return false;
    }

    for (name) |char| {
        if (!std.ascii.isLower(char) and !std.ascii.isDigit(char) and char != '_') {
            return false;
        }
    }

    return true;
}

test "collections: names, unique kinds, indexed fields" {
    const good = [_]Collection{
        .{
            .kind = "movement",
            .indexed = &.{ "stock", "at" },
            .append_only = true,
        },
        .{
            .kind = "cart",
        },
    };

    try std.testing.expect(problem(&good) == null);
    try std.testing.expect(find(&good, "cart") != null);
    try std.testing.expect(find(&good, "order") == null);
    try std.testing.expect(indexes(good[0], "stock"));
    try std.testing.expect(!indexes(good[0], "reason"));

    const twice = [_]Collection{ .{
        .kind = "cart",
    }, .{
        .kind = "cart",
    } };
    const badly_named = [_]Collection{.{
        .kind = "Cart",
    }};
    const field_twice = [_]Collection{.{
        .kind = "cart",
        .indexed = &.{ "a", "a" },
    }};

    try std.testing.expect(problem(&twice) != null);
    try std.testing.expect(problem(&badly_named) != null);
    try std.testing.expect(problem(&field_twice) != null);
}

test "indexed values: text, integers and booleans only" {
    var buffer: [256]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const arena = fixed.allocator();

    try std.testing.expectEqualStrings("tea", (try indexed_text(arena, .{
        .string = "tea",
    })).?);
    try std.testing.expectEqualStrings("42", (try indexed_text(arena, .{
        .integer = 42,
    })).?);
    try std.testing.expectEqualStrings("true", (try indexed_text(arena, .{
        .bool = true,
    })).?);
    try std.testing.expect(try indexed_text(arena, .{
        .float = 1.5,
    }) == null);
    try std.testing.expect(try indexed_text(arena, .null) == null);
}
