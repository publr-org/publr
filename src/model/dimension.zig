//! Dimensions: a field may hold a value per combination of the dimensions it varies by (a
//! language, an A/B test's variation), each kept under its name with the combination
//! appended, `title@language=pl,variation=b` beside `title`. The plain name holds the main
//! value of every dimension; a combination names only the dimensions not at their main
//! value, sorted by name. What a dimension is belongs to whoever declares it; the core only
//! stores, reads and picks values. Reading in a combination is `dimension/resolve.zig`.

const std = @import("std");

pub const resolve = @import("dimension/resolve.zig");
pub const live = @import("dimension/live.zig");

pub const code_len_max: u32 = 16;
pub const name_len_max: u32 = 32;
/// The dimensions one site has at most: a language and many A/B tests.
pub const dimensions_max: u32 = 64;
/// The dimensions one value names at most (`title@language=pl,hero=b`): a value is rarely in
/// more than a language and a test or two, and this keeps keys short.
pub const key_pairs_max: u32 = 4;
/// The codes one dimension falls back through: the code, each shorter prefix, its main.
pub const order_max: u32 = 5;
pub const separator: u8 = '@';
/// Between a family's name and one of its dimensions': `variation-hero`, an A/B test's.
pub const member_separator: u8 = '-';
/// A field that varies by every dimension the site has, whichever they are.
pub const every = "*";
pub const combination_len_max: u32 = key_pairs_max * (name_len_max + code_len_max + 2);

/// A dimension as data: what an installed plugin's manifest says of the one it declares, its
/// list an operation by full name (`languages.list`), its wrapper as the owner words it.
pub const Declared = struct {
    name: []const u8,
    /// Its key in an address's query (`lang`); empty: its name.
    param: []const u8 = "",
    list: []const u8,
    /// Higher keeps its value longer when a combination falls back.
    priority: i32 = 0,
    /// Its values have pages of their own, under their addresses.
    addresses: bool = false,
    /// The plugin declaring it, set where the site gathers them.
    plugin: []const u8 = "",
    /// How a field says it holds values per this dimension (`.translatable = .required`).
    field: FieldOption,
    /// What a read names it by (`.language = "pl"`); empty: by its name.
    read: ReadOption = .{},
    /// A family: one dimension per thing its owner lists (`variation-hero`, each A/B test its
    /// own), its list answering `dimensions`, each with its values. A field holding the
    /// family holds each of them.
    each: bool = false,
    /// The owner's read telling, for one record, which of its fields each of the family's
    /// dimensions shows on (`shown`); empty: every field holding it, on every record.
    shown: []const u8 = "",
    /// How a field that says nothing of it holds it; a field saying otherwise is kept in its
    /// `not_in` (`one`) or `dimensions`.
    default: Holds = .one,
};

/// The owner's field option: its name, words, and each value it takes with its `Holds`.
pub const FieldOption = struct {
    /// `translatable`.
    name: []const u8,
    /// The setting on the field panel: `Translate`.
    label: []const u8,
    /// What the setting means, under it.
    help: []const u8 = "",
    /// Each value in the order the owner declares it, no two holding the same way.
    choices: []const Choice,
    /// The owner draws the setting itself (`.options`); else the core lists the choices.
    drawn: bool = false,
};

pub const Choice = struct {
    /// `optional_with_fallback`.
    value: []const u8,
    holds: Holds,
    /// The owner's words for it: a first line, then what it means.
    title: []const u8,
    description: []const u8 = "",
};

/// The owner's read option: its name and the editor picker's word.
pub const ReadOption = struct {
    /// `language`; empty: the dimension's name.
    name: []const u8 = "",
    /// The editor's picker: `Content language`; empty: the field option's label.
    label: []const u8 = "",
};

pub const choices_max: u32 = 16;

/// The choice of `option` holding values `holds`, if it has one.
pub fn choice_holding(option: FieldOption, holds: Holds) ?Choice {
    std.debug.assert(option.choices.len <= choices_max);

    for (option.choices) |choice| {
        if (choice.holds == holds) {
            return choice;
        }
    }

    return null;
}

/// How the choice of `option` named `value` holds values, if it has one so named.
pub fn holds_named(option: FieldOption, value: []const u8) ?Holds {
    std.debug.assert(option.choices.len <= choices_max);

    for (option.choices) |choice| {
        if (std.mem.eql(u8, choice.value, value)) {
            return choice.holds;
        }
    }

    return null;
}

/// How a field holds values per a dimension: one for all (not varying by it), each going
/// live filled (`required`), an empty one showing nothing (`empty`) or the main value
/// (`fallback`).
pub const Holds = enum { one, required, empty, fallback };

/// How `def` holds values per `name`, from its `dimensions`, `required_in` and `empty_in`;
/// a family's dimension (`variation-hero`) as it holds the family.
pub fn holds_of(def: anytype, name: []const u8) Holds {
    std.debug.assert(name.len > 0);

    const family = family_of(name);

    if (!varies_by(def.dimensions, name)) {
        return .one;
    }

    if (lists(def.required_in, name) or lists(def.required_in, family)) {
        return .required;
    }

    const empty = lists(def.empty_in, name) or lists(def.empty_in, family);

    return if (empty) .empty else .fallback;
}

/// The family `name` is one of (`variation` for `variation-hero`); `name` itself for a
/// dimension of its own.
pub fn family_of(name: []const u8) []const u8 {
    std.debug.assert(name.len > 0);

    const at = std.mem.indexOfScalar(u8, name, member_separator) orelse return name;

    return name[0..at];
}

/// `family-member` from both names, or null when it is no valid dimension name.
pub fn member_name(
    arena: std.mem.Allocator,
    family: []const u8,
    member: []const u8,
) error{OutOfMemory}!?[]const u8 {
    std.debug.assert(family.len > 0);

    const name = try std.fmt.allocPrint(arena, "{s}{c}{s}", .{ family, member_separator, member });

    return if (valid_dimension(name)) name else null;
}

/// Each a dimension's name, at most as many as a site has.
pub fn valid_names(names: []const []const u8) bool {
    std.debug.assert(dimensions_max > 0);

    if (names.len > dimensions_max) {
        return false;
    }

    for (names) |name| {
        if (!valid_name(name)) {
            return false;
        }
    }

    return true;
}

/// Whether `names` lists `name`.
pub fn lists(names: []const []const u8, name: []const u8) bool {
    std.debug.assert(names.len <= dimensions_max);

    for (names) |listed| {
        if (std.mem.eql(u8, listed, name)) {
            return true;
        }
    }

    return false;
}

/// One dimension at one value: `language` at `pl`. An empty code is its main value.
pub const Pair = struct {
    dimension: []const u8,
    code: []const u8,
};

/// The dimensions a key names, at most `key_pairs_max`, sorted by name.
pub const Combination = struct {
    pairs: [key_pairs_max]Pair = undefined,
    len: u32 = 0,

    pub fn slice(combination: *const Combination) []const Pair {
        std.debug.assert(combination.len <= key_pairs_max);

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

/// A dimension's name as values are kept under it: a name, or a family's dimension
/// (`variation-hero`), its family's name and its own joined by a dash.
pub fn valid_dimension(name: []const u8) bool {
    if (name.len == 0 or name.len > name_len_max) {
        return false;
    }

    std.debug.assert(name.len <= name_len_max);

    const at = std.mem.indexOfScalar(u8, name, member_separator) orelse return valid_name(name);

    return valid_name(name[0..at]) and valid_name(name[at + 1 ..]);
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

        if (combination.len == key_pairs_max or !valid_dimension(pair.dimension)) {
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

/// Whether a field varying by `dimensions` varies by `dimension`: listed, its family listed
/// (`variation` for `variation-hero`), or every one.
pub fn varies_by(dimensions: []const []const u8, dimension: []const u8) bool {
    std.debug.assert(dimension.len > 0);

    const family = family_of(dimension);

    for (dimensions) |name| {
        if (std.mem.eql(u8, name, every) or std.mem.eql(u8, name, dimension)) {
            return true;
        }

        if (std.mem.eql(u8, name, family)) {
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

/// `key_of` written into `buffer`; null when it does not fit, or names more than
/// `key_pairs_max` dimensions.
pub fn key_into(buffer: []u8, name: []const u8, pairs: []const Pair) ?[]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(pairs.len <= dimensions_max);

    var sorted: [key_pairs_max]Pair = undefined;
    var len: u32 = 0;

    for (pairs) |pair| {
        if (pair.code.len == 0) {
            continue;
        }

        if (len == key_pairs_max) {
            return null;
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
    code: []const u8 = "",
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
    try std.testing.expect(fits(&.{"variation"}, "variation-hero=b"));
    try std.testing.expect(!fits(&.{"variation"}, "variant-hero=b"));
    try std.testing.expect(parse("variation-hero-x=b") == null);
    try std.testing.expectEqualStrings("variation", family_of("variation-hero"));
    try std.testing.expectEqualStrings("language", family_of("language"));
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
    _ = live;
}
