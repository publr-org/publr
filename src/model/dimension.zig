//! Dimensions: a field may hold a value per combination of the dimensions it varies by (a
//! language, an A/B test's variation), each kept under its name with the combination
//! appended, `title@language=pl,variation=b` beside `title`. The plain name holds the main
//! value of every dimension; a combination names only the dimensions not at their main
//! value, sorted by name. What a dimension is belongs to whoever declares it; the core only
//! stores, reads and picks values. Reading in a combination is `dimension/resolve.zig`.

const std = @import("std");
const public = @import("../publr/model/dimension.zig");

pub const resolve = @import("dimension/resolve.zig");
pub const live = @import("dimension/live.zig");

pub const code_len_max = public.code_len_max;
pub const name_len_max = public.name_len_max;
pub const dimensions_max = public.dimensions_max;
pub const key_pairs_max = public.key_pairs_max;
/// The codes one dimension falls back through: the code, each shorter prefix, its main.
pub const order_max: u32 = 5;
pub const separator = public.separator;
pub const member_separator = public.member_separator;
pub const every = public.every;
pub const combination_len_max = public.combination_len_max;

pub const Declared = public.Declared;
pub const FieldOption = public.FieldOption;
pub const Choice = public.Choice;
pub const ReadOption = public.ReadOption;
pub const choices_max = public.choices_max;

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

pub const Holds = public.Holds;

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

pub const family_of = public.family_of;

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

pub const Pair = public.Pair;

pub const Combination = public.Combination;

pub const valid_code = public.valid_code;
pub const valid_name = public.valid_name;
pub const valid_dimension = public.valid_dimension;

pub const Key = public.Key;
pub const split = public.split;
pub const parse = public.parse;

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

pub const varies_by = public.varies_by;

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
