//! Dimensions: a field may hold a value per combination of the dimensions it varies by (a
//! language, an A/B test's variation), each kept under its name with the combination
//! appended, `title@language=pl,variation=b` beside `title`. The plain name holds the main
//! value of every dimension; a combination names only the dimensions not at their main
//! value, sorted by name. What a dimension is belongs to whoever declares it; the core only
//! stores, reads and picks values. Reading in a combination is `dimension/resolve.zig`.

const std = @import("std");

pub const resolve = @import("dimension/resolve.zig");

pub const code_len_max: u32 = 16;
pub const name_len_max: u32 = 32;
/// The dimensions one site has, and so one combination names at most.
pub const dimensions_max: u32 = 4;
/// The codes one dimension falls back through: the code, each shorter prefix, its main.
pub const order_max: u32 = 5;
pub const separator: u8 = '@';
/// A field that varies by every dimension the site has, whichever they are.
pub const every = "*";
const combination_len_max: u32 = dimensions_max * (name_len_max + code_len_max + 2);

/// The type setting for records with no value in a combination: shown in the main values
/// (`keep`), or left out of it (`omit`). Unnamed: the setting is not offered.
pub const Untranslated = struct {
    label: []const u8 = "",
    keep: []const u8 = "",
    keep_help: []const u8 = "",
    omit: []const u8 = "",
    omit_help: []const u8 = "",
};

/// A dimension as data: what an installed plugin's manifest says of the one it declares, its
/// list an operation by full name (`languages.list`).
pub const Declared = struct {
    name: []const u8,
    label: []const u8,
    help: []const u8,
    picker: []const u8 = "",
    list: []const u8,
    /// Higher keeps its value longer when a combination falls back.
    priority: i32 = 0,
    /// Its values have pages of their own, under their addresses.
    addresses: bool = false,
    untranslated: Untranslated = .{},
};

/// One dimension at one value: `language` at `pl`. An empty code is its main value.
pub const Pair = struct {
    dimension: []const u8,
    code: []const u8,
};

/// The dimensions a key names, at most `dimensions_max`, sorted by name.
pub const Combination = struct {
    pairs: [dimensions_max]Pair = undefined,
    len: u32 = 0,

    pub fn slice(combination: *const Combination) []const Pair {
        std.debug.assert(combination.len <= dimensions_max);

        return combination.pairs[0..combination.len];
    }

    /// The code `dimension` is at, empty for its main value.
    pub fn code_of(combination: *const Combination, dimension: []const u8) []const u8 {
        std.debug.assert(dimension.len > 0);

        for (combination.slice()) |pair| {
            if (std.mem.eql(u8, pair.dimension, dimension)) {
                return pair.code;
            }
        }

        return "";
    }
};

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

/// A dimension's name: lowercase letters, digits and underscores, a letter first.
pub fn valid_name(name: []const u8) bool {
    if (name.len == 0 or name.len > name_len_max or !std.ascii.isLower(name[0])) {
        return false;
    }

    std.debug.assert(name.len <= name_len_max);

    for (name) |char| {
        if (!(std.ascii.isLower(char) or std.ascii.isDigit(char) or char == '_')) {
            return false;
        }
    }

    return true;
}

pub const Key = struct {
    name: []const u8,
    /// `language=pl,variation=b`; empty for the main value.
    combination: []const u8,
};

/// `title@language=pl` as its field's name and the combination; a plain name has none.
pub fn split(key: []const u8) Key {
    std.debug.assert(key.len <= 64 << 10);

    const at = std.mem.indexOfScalar(u8, key, separator) orelse return .{
        .name = key,
        .combination = "",
    };

    return .{
        .name = key[0..at],
        .combination = key[at + 1 ..],
    };
}

/// `language=pl,variation=b` read: each a valid name and code, names sorted and each once,
/// none at its main value. Null for anything else, the empty text included.
pub fn parse(text: []const u8) ?Combination {
    std.debug.assert(text.len <= 64 << 10);

    if (text.len == 0 or text.len > combination_len_max) {
        return null;
    }

    var combination: Combination = .{};
    var parts = std.mem.splitScalar(u8, text, ',');

    while (parts.next()) |part| {
        const equals = std.mem.indexOfScalar(u8, part, '=') orelse return null;
        const pair: Pair = .{
            .dimension = part[0..equals],
            .code = part[equals + 1 ..],
        };

        if (combination.len == dimensions_max or !valid_name(pair.dimension)) {
            return null;
        }

        if (!valid_code(pair.code)) {
            return null;
        }

        if (combination.len > 0) {
            const previous = combination.pairs[combination.len - 1].dimension;

            if (!std.mem.lessThan(u8, previous, pair.dimension)) {
                return null;
            }
        }

        combination.pairs[combination.len] = pair;
        combination.len += 1;
    }

    return combination;
}

/// Whether `text` is a combination a field varying by `dimensions` may hold.
pub fn fits(dimensions: []const []const u8, text: []const u8) bool {
    std.debug.assert(dimensions.len <= dimensions_max + 1);

    const combination = parse(text) orelse return false;

    for (combination.slice()) |pair| {
        if (!varies_by(dimensions, pair.dimension)) {
            return false;
        }
    }

    return true;
}

/// Whether a field varying by `dimensions` varies by `dimension`.
pub fn varies_by(dimensions: []const []const u8, dimension: []const u8) bool {
    std.debug.assert(dimension.len > 0);

    for (dimensions) |name| {
        if (std.mem.eql(u8, name, every) or std.mem.eql(u8, name, dimension)) {
            return true;
        }
    }

    return false;
}

/// The key of `name` in `pairs`: `name@<combination>`, the pairs at a main value left out,
/// the rest sorted by dimension; `name` alone when none is left.
pub fn key_of(
    arena: std.mem.Allocator,
    name: []const u8,
    pairs: []const Pair,
) error{OutOfMemory}![]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(pairs.len <= dimensions_max);

    var buffer: [combination_len_max + name_len_max * 2]u8 = undefined;
    const key = key_into(&buffer, name, pairs) orelse return error.OutOfMemory;

    return arena.dupe(u8, key);
}

/// `key_of` written into `buffer`; null when it does not fit.
pub fn key_into(buffer: []u8, name: []const u8, pairs: []const Pair) ?[]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(pairs.len <= dimensions_max);

    var sorted: [dimensions_max]Pair = undefined;
    var len: u32 = 0;

    for (pairs) |pair| {
        if (pair.code.len == 0) {
            continue;
        }

        var at = len;

        while (at > 0 and std.mem.lessThan(u8, pair.dimension, sorted[at - 1].dimension)) {
            sorted[at] = sorted[at - 1];
            at -= 1;
        }

        sorted[at] = pair;
        len += 1;
    }

    var writer: std.Io.Writer = .fixed(buffer);

    writer.writeAll(name) catch return null;

    for (sorted[0..len], 0..) |pair, index| {
        const lead: u8 = if (index == 0) separator else ',';

        writer.print("{c}{s}={s}", .{ lead, pair.dimension, pair.code }) catch return null;
    }

    return writer.buffered();
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

/// Where a page of the site is: the language part of the combination its documents are read
/// in, the language it says it is in (`<html lang>`), and the address its pages are under.
pub const Place = struct {
    /// The code its values are stored under: empty for the main language.
    variant: []const u8 = "",
    /// The language's own code, the main one's too (`en`); empty on a site with none.
    locale: []const u8 = "",
    /// `/pl`; empty for the main language.
    address: []const u8 = "",
    /// The other dimensions the request chose a value in (a request hook's variation): read
    /// live, kept out of shared caches.
    chosen: []const Pair = &.{},
};

/// A path under an address: `/pl` and `/` give `/pl`, `/pl` and `/about` give `/pl/about`.
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

test "codes and names: the shapes they take" {
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
    try std.testing.expect(valid_name("language"));
    try std.testing.expect(valid_name("ab_test2"));
    try std.testing.expect(!valid_name(""));
    try std.testing.expect(!valid_name("Language"));
    try std.testing.expect(!valid_name("2nd"));
    try std.testing.expect(!valid_name("a-b"));
}

test "combinations: written sorted, main values left out, read back strictly" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const key = try key_of(arena, "title", &.{
        .{
            .dimension = "variation",
            .code = "b",
        },
        .{
            .dimension = "language",
            .code = "pl",
        },
    });

    try std.testing.expectEqualStrings("title@language=pl,variation=b", key);
    try std.testing.expectEqualStrings("title", try key_of(arena, "title", &.{
        .{
            .dimension = "language",
            .code = "",
        },
    }));
    try std.testing.expectEqualStrings("title@variation=b", try key_of(arena, "title", &.{
        .{
            .dimension = "language",
            .code = "",
        },
        .{
            .dimension = "variation",
            .code = "b",
        },
    }));

    const read = split(key);
    const combination = parse(read.combination).?;

    try std.testing.expectEqualStrings("title", read.name);
    try std.testing.expectEqual(@as(u32, 2), combination.len);
    try std.testing.expectEqualStrings("pl", combination.code_of("language"));
    try std.testing.expectEqualStrings("", combination.code_of("edition"));
    try std.testing.expect(parse("") == null);
    try std.testing.expect(parse("pl") == null);
    try std.testing.expect(parse("variation=b,language=pl") == null);
    try std.testing.expect(parse("language=pl,language=en") == null);
    try std.testing.expect(parse("language=") == null);
    try std.testing.expect(parse("a=x,b=x,c=x,d=x,e=x") == null);
    try std.testing.expect(fits(&.{ "language", "variation" }, "language=pl,variation=b"));
    try std.testing.expect(fits(&.{every}, "language=pl"));
    try std.testing.expect(!fits(&.{"language"}, "language=pl,variation=b"));
    try std.testing.expect(!fits(&.{}, "language=pl"));
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

test "order: the code, its shorter prefixes, the main value" {
    var buffer: [order_max][]const u8 = undefined;
    const codes = order("zh-hant-tw", &buffer);

    try std.testing.expectEqual(@as(usize, 4), codes.len);
    try std.testing.expectEqualStrings("zh-hant-tw", codes[0]);
    try std.testing.expectEqualStrings("zh-hant", codes[1]);
    try std.testing.expectEqualStrings("zh", codes[2]);
    try std.testing.expectEqualStrings("", codes[3]);
    try std.testing.expectEqual(@as(usize, 1), order("", &buffer).len);
}

test {
    _ = resolve;
}
