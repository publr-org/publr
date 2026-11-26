//! A field's values per dimension as plugins read them: `title@language=pl,variation=b`
//! beside `title`, split into its name and combination, each pair a dimension at a code.
const std = @import("std");

pub const code_len_max: u32 = 16;
pub const name_len_max: u32 = 32;
/// The dimensions one value names at most (`title@language=pl,hero=b`): a value is rarely in
/// more than a language and a test or two, and this keeps keys short.
pub const key_pairs_max: u32 = 4;
pub const separator: u8 = '@';
/// Between a family's name and one of its dimensions': `variation-hero`, an A/B test's.
pub const member_separator: u8 = '-';
/// A field that varies by every dimension the site has, whichever they are.
pub const every = "*";
pub const combination_len_max: u32 = key_pairs_max * (name_len_max + code_len_max + 2);

/// How a field holds values per a dimension: one for all (not varying by it), each going
/// live filled (`required`), an empty one showing nothing (`empty`) or the main value
/// (`fallback`).
pub const Holds = enum { one, required, empty, fallback };

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

pub const Key = struct {
    name: []const u8,
    /// `language=pl,variation=b`; empty for the main value.
    combination: []const u8,
};

/// The family `name` is one of (`variation` for `variation-hero`); `name` itself for a
/// dimension of its own.
pub fn family_of(name: []const u8) []const u8 {
    std.debug.assert(name.len > 0);

    const at = std.mem.indexOfScalar(u8, name, member_separator) orelse return name;

    return name[0..at];
}

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
