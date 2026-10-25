//! Variants: a field that holds a value per variant keeps each under its name with the
//! variant's code appended, `name@pl` beside `name`. The plain name holds the main value. What
//! a variant is belongs to whoever declares the dimension (the languages plugin: a language);
//! the core only stores, reads and picks them. A document read whole carries every variant
//! beside its field; a document read in a variant carries one value per field, the variant's
//! when it has one, else the variant without its region's (`en-gb` falls back to `en`), else
//! the main value.

const std = @import("std");
const field = @import("field.zig");

const Def = field.Def;
const Value = std.json.Value;

pub const code_len_max: u32 = 16;

/// The type setting for records not written in a variant: shown in its main values
/// (`keep`), or left out of it (`omit`). Unnamed: the setting is not offered.
pub const Untranslated = struct {
    label: []const u8 = "",
    keep: []const u8 = "",
    keep_help: []const u8 = "",
    omit: []const u8 = "",
    omit_help: []const u8 = "",
};

/// A variant dimension as data: what an installed plugin's manifest says of the one it
/// declares, its list an operation by full name (`languages.list`).
pub const Declared = struct {
    label: []const u8,
    help: []const u8,
    picker: []const u8 = "",
    list: []const u8,
    untranslated: Untranslated = .{},
};
/// The codes one read falls back through: the variant, each shorter prefix, the main value.
pub const order_max: u32 = 5;
pub const separator: u8 = '@';

/// Lowercase letters, digits and dashes, a letter first, no dash last or twice in a row:
/// `pl`, `en-gb`, `zh-hant-tw`.
pub fn valid_code(code: []const u8) bool {
    if (code.len == 0 or code.len > code_len_max) {
        return false;
    }

    std.debug.assert(code.len <= code_len_max);

    if (!std.ascii.isLower(code[0]) or code[code.len - 1] == '-') {
        return false;
    }

    for (code, 0..) |char, index| {
        const dash = char == '-';

        if (!(std.ascii.isLower(char) or std.ascii.isDigit(char) or dash)) {
            return false;
        }

        if (dash and code[index - 1] == '-') {
            return false;
        }
    }

    return true;
}

pub const Key = struct {
    name: []const u8,
    /// Empty for the main value.
    code: []const u8,
};

/// Where a page of the site is, by language: the variant its documents are read in, the
/// language it says it is in (`<html lang>`), and the address its pages are under.
pub const Place = struct {
    /// The code its values are stored under: empty for the main variant.
    variant: []const u8 = "",
    /// The variant's own code, the main one's too (`en`); empty on a site with none.
    locale: []const u8 = "",
    /// `/pl`; empty for the main variant.
    address: []const u8 = "",
};

/// A path under a variant's address: `/pl` and `/` give `/pl`, `/pl` and `/about` give
/// `/pl/about`.
pub fn under(
    arena: std.mem.Allocator,
    address: []const u8,
    path: []const u8,
) error{OutOfMemory}![]const u8 {
    std.debug.assert(path.len > 0 and path[0] == '/');
    std.debug.assert(address.len == 0 or address[0] == '/');

    if (address.len == 0) {
        return path;
    }

    if (std.mem.eql(u8, path, "/")) {
        return address;
    }

    return std.mem.concat(arena, u8, &.{ address, path });
}

/// The path without the address it is under, or null when it is not under it.
pub fn beneath(address: []const u8, path: []const u8) ?[]const u8 {
    std.debug.assert(address.len > 1 and address[0] == '/');
    std.debug.assert(path.len > 0);

    if (!std.mem.startsWith(u8, path, address)) {
        return null;
    }

    const rest = path[address.len..];

    if (rest.len == 0) {
        return "/";
    }

    return if (rest[0] == '/') rest else null;
}

/// `title@pl` as its field's name and the code; a plain name has no code.
pub fn split(key: []const u8) Key {
    std.debug.assert(key.len <= 64 << 10);

    const at = std.mem.indexOfScalar(u8, key, separator) orelse return .{
        .name = key,
        .code = "",
    };

    return .{
        .name = key[0..at],
        .code = key[at + 1 ..],
    };
}

/// The key of `name` in `code`: `name@code`, or `name` for the main value.
pub fn key_of(
    arena: std.mem.Allocator,
    name: []const u8,
    code: []const u8,
) error{OutOfMemory}![]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(code.len <= code_len_max);

    if (code.len == 0) {
        return name;
    }

    return std.fmt.allocPrint(arena, "{s}@{s}", .{ name, code });
}

/// Where a read in `code` looks, in turn: `en-gb` then `en` then the main value.
pub fn order(code: []const u8, buffer: *[order_max][]const u8) []const []const u8 {
    std.debug.assert(code.len <= code_len_max);
    std.debug.assert(buffer.len == order_max);

    var len: u32 = 0;
    var rest = code;

    while (rest.len > 0 and len < order_max - 1) {
        buffer[len] = rest;
        len += 1;

        const dash = std.mem.lastIndexOfScalar(u8, rest, '-') orelse break;

        rest = rest[0..dash];
    }

    buffer[len] = "";
    len += 1;

    return buffer[0..len];
}

/// The document as read in `code`: every field that holds variants gives the value of the
/// first code in `order(code)` it has, under its plain name; the `@` keys go. Groups and
/// repeaters are read in the same variant all the way down. `code` empty reads the main
/// values. A value kept empty on purpose (`""`) counts as given.
pub fn resolve(
    arena: std.mem.Allocator,
    fields: []const Def,
    document: Value,
    code: []const u8,
) error{OutOfMemory}!Value {
    std.debug.assert(fields.len <= field.fields_max);
    std.debug.assert(code.len <= code_len_max);

    if (document != .object) {
        return document;
    }

    var buffer: [order_max][]const u8 = undefined;
    const codes = order(code, &buffer);

    return resolve_object(arena, fields, document.object, codes);
}

fn resolve_object(
    arena: std.mem.Allocator,
    fields: []const Def,
    object: std.json.ObjectMap,
    codes: []const []const u8,
) error{OutOfMemory}!Value {
    std.debug.assert(fields.len <= field.fields_max);
    std.debug.assert(codes.len > 0);

    var out: std.json.ObjectMap = .empty;
    var entries = object.iterator();

    // What the type does not describe passes through as it is, but no `@` key does.
    while (entries.next()) |entry| {
        const key = split(entry.key_ptr.*);

        if (key.code.len > 0 or field_named(fields, key.name) != null) {
            continue;
        }

        try out.put(arena, entry.key_ptr.*, entry.value_ptr.*);
    }

    for (fields) |*def| {
        const picked = try pick(arena, def, object, codes) orelse continue;

        try out.put(arena, def.name, try resolve_value(arena, def, picked, codes));
    }

    return .{
        .object = out,
    };
}

fn pick(
    arena: std.mem.Allocator,
    def: *const Def,
    object: std.json.ObjectMap,
    codes: []const []const u8,
) error{OutOfMemory}!?Value {
    std.debug.assert(def.name.len > 0);
    std.debug.assert(codes.len > 0);

    if (!def.variants) {
        return object.get(def.name);
    }

    for (codes) |code| {
        const key = try key_of(arena, def.name, code);

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
    codes: []const []const u8,
) error{OutOfMemory}!Value {
    std.debug.assert(def.name.len > 0);
    std.debug.assert(codes.len > 0);

    if (def.fields.len == 0 or !field.is_container(def.kind)) {
        return value;
    }

    if (field.is_group(def.kind)) {
        if (value != .object) {
            return value;
        }

        return resolve_object(arena, def.fields, value.object, codes);
    }

    if (value != .array) {
        return value;
    }

    var items = std.json.Array.init(arena);

    for (value.array.items) |item| {
        const resolved = if (item == .object)
            try resolve_object(arena, def.fields, item.object, codes)
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

/// The codes a document carries anywhere in it, each once, in the order first met.
pub fn codes_in(
    arena: std.mem.Allocator,
    fields: []const Def,
    document: Value,
) error{OutOfMemory}![]const []const u8 {
    std.debug.assert(fields.len <= field.fields_max);

    var found: std.ArrayList([]const u8) = .empty;

    try collect_codes(arena, fields, document, &found);

    return found.items;
}

fn collect_codes(
    arena: std.mem.Allocator,
    fields: []const Def,
    value: Value,
    found: *std.ArrayList([]const u8),
) error{OutOfMemory}!void {
    std.debug.assert(fields.len <= field.fields_max);

    switch (value) {
        .array => |array| for (array.items) |item| {
            try collect_codes(arena, fields, item, found);
        },
        .object => |object| {
            var entries = object.iterator();

            while (entries.next()) |entry| {
                const key = split(entry.key_ptr.*);
                const def = field_named(fields, key.name) orelse continue;

                if (key.code.len > 0 and def.variants and !contains(found.items, key.code)) {
                    try found.append(arena, key.code);
                }

                if (field.is_container(def.kind)) {
                    try collect_codes(arena, def.fields, entry.value_ptr.*, found);
                }
            }
        },
        else => {},
    }
}

fn contains(codes: []const []const u8, code: []const u8) bool {
    std.debug.assert(code.len > 0);

    for (codes) |known| {
        if (std.mem.eql(u8, known, code)) {
            return true;
        }
    }

    return false;
}

test "codes: the shapes a variant's code takes" {
    try std.testing.expect(valid_code("pl"));
    try std.testing.expect(valid_code("en-gb"));
    try std.testing.expect(valid_code("zh-hant-tw"));
    try std.testing.expect(!valid_code(""));
    try std.testing.expect(!valid_code("PL"));
    try std.testing.expect(!valid_code("-pl"));
    try std.testing.expect(!valid_code("pl-"));
    try std.testing.expect(!valid_code("en--gb"));
    try std.testing.expect(!valid_code("en_gb"));
    try std.testing.expect(!valid_code("1en"));
}

test "places: a path under an address and back" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("/pl", try under(arena, "/pl", "/"));
    try std.testing.expectEqualStrings("/pl/about", try under(arena, "/pl", "/about"));
    try std.testing.expectEqualStrings("/about", try under(arena, "", "/about"));
    try std.testing.expectEqualStrings("/", beneath("/pl", "/pl").?);
    try std.testing.expectEqualStrings("/about", beneath("/pl", "/pl/about").?);
    try std.testing.expect(beneath("/pl", "/plans") == null);
    try std.testing.expect(beneath("/pl", "/about") == null);
}

test "order: the variant, its shorter prefixes, the main value" {
    var buffer: [order_max][]const u8 = undefined;
    const codes = order("zh-hant-tw", &buffer);

    try std.testing.expectEqual(@as(usize, 4), codes.len);
    try std.testing.expectEqualStrings("zh-hant-tw", codes[0]);
    try std.testing.expectEqualStrings("zh-hant", codes[1]);
    try std.testing.expectEqualStrings("zh", codes[2]);
    try std.testing.expectEqualStrings("", codes[3]);
    try std.testing.expectEqual(@as(usize, 1), order("", &buffer).len);
}

test "resolve: each field in the variant, else its fallback, nested ones too" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const items = [_]Def{.{
        .name = "heading",
        .label = "Heading",
        .kind = "string",
        .variants = true,
    }};
    const fields = [_]Def{
        .{
            .name = "name",
            .label = "Name",
            .kind = "string",
            .variants = true,
        },
        .{
            .name = "note",
            .label = "Note",
            .kind = "string",
            .variants = true,
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
        \\{"name":"Mug","name@en":"Mug (en)","name@pl":"Kubek","note":"Glazed","note@pl":"",
        \\"price":4900,"sections":[{"heading":"One","heading@pl":"Jeden"},{"heading":"Two"}],
        \\"_extra":1}
    ;
    const document = try std.json.parseFromSliceLeaky(Value, arena, text, .{});
    const polish = try resolve(arena, &fields, document, "pl");

    try std.testing.expectEqualStrings("Kubek", polish.object.get("name").?.string);
    try std.testing.expectEqualStrings("", polish.object.get("note").?.string);
    try std.testing.expectEqual(@as(i64, 4900), polish.object.get("price").?.integer);
    try std.testing.expect(polish.object.get("name@pl") == null);
    try std.testing.expect(polish.object.get("_extra") != null);

    const sections = polish.object.get("sections").?.array.items;

    try std.testing.expectEqualStrings("Jeden", sections[0].object.get("heading").?.string);
    try std.testing.expectEqualStrings("Two", sections[1].object.get("heading").?.string);

    const british = try resolve(arena, &fields, document, "en-gb");

    try std.testing.expectEqualStrings("Mug (en)", british.object.get("name").?.string);
    try std.testing.expectEqualStrings("Glazed", british.object.get("note").?.string);

    const main = try resolve(arena, &fields, document, "");

    try std.testing.expectEqualStrings("Mug", main.object.get("name").?.string);

    const codes = try codes_in(arena, &fields, document);

    try std.testing.expectEqual(@as(usize, 2), codes.len);
}
