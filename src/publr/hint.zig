//! What an operation says to an agent about itself, beyond its description: the words
//! `publr find` also matches it by (`find_words`), and the hint shown when a field that
//! probably wanted it is added (`hint`). A compiled-in operation declares them as
//! `pub const find_words` and `pub const hint`; a plugin's operation writes them in its
//! words, on a `Find:` and a `Hint:` line. Hints only warn: nothing is ever refused for one.
const std = @import("std");

/// The fields a hint names at most.
pub const fields_max: u32 = 16;
/// The longest hint sentence.
pub const says_len_max: u32 = 240;

/// Shown when a field named one of `fields` is added to a type, in the answer of whatever
/// added it (`content_type create`, `plugin check`).
pub const Hint = struct {
    /// Field names it is shown for, lower case: `category`, `tags`.
    fields: []const []const u8,
    /// One sentence: what fits better.
    says: []const u8,
};

/// A hint as an answer carries it, about one field.
pub const Hinted = struct {
    field: []const u8,
    says: []const u8,
    /// The command it points to: `taxonomy create`.
    see: []const u8,
};

/// An operation's `find_words`, empty when it declares none.
pub fn find_words(comptime Operation: type) []const u8 {
    return if (@hasDecl(Operation, "find_words")) Operation.find_words else "";
}

/// An operation's `hint`, null when it declares none.
pub fn hint_of(comptime Operation: type) ?Hint {
    return if (@hasDecl(Operation, "hint")) Operation.hint else null;
}

/// Whether `field` is one the hint is shown for, its case ignored.
pub fn names(hint: Hint, field: []const u8) bool {
    std.debug.assert(hint.fields.len <= fields_max);

    for (hint.fields) |named| {
        if (std.ascii.eqlIgnoreCase(named, field)) {
            return true;
        }
    }

    return false;
}

/// A `Hint:` line's text after the label, `category, tags: what fits better`, read; null
/// when it has no `: ` between its names and its sentence, or names none.
pub fn parse(comptime text: []const u8) ?Hint {
    comptime {
        std.debug.assert(text.len > 0);

        const cut = std.mem.indexOf(u8, text, ": ") orelse return null;
        const says = std.mem.trim(u8, text[cut + 2 ..], " ");
        var fields: []const []const u8 = &.{};
        var each = std.mem.splitScalar(u8, text[0..cut], ',');

        while (each.next()) |raw| {
            const one = std.mem.trim(u8, raw, " ");

            if (one.len > 0) {
                fields = fields ++ [_][]const u8{lower(one)};
            }
        }

        if (fields.len == 0 or says.len == 0) {
            return null;
        }

        return .{
            .fields = fields,
            .says = says,
        };
    }
}

fn lower(comptime text: []const u8) []const u8 {
    comptime {
        std.debug.assert(text.len > 0);

        var out: [text.len]u8 = undefined;

        for (text, 0..) |byte, index| {
            out[index] = std.ascii.toLower(byte);
        }

        const done = out;

        return &done;
    }
}

test "a Hint: line reads its names and its sentence" {
    const hint = comptime parse("Category, tags: shared lists are a taxonomy").?;

    try std.testing.expectEqual(@as(usize, 2), hint.fields.len);
    try std.testing.expectEqualStrings("category", hint.fields[0]);
    try std.testing.expectEqualStrings("shared lists are a taxonomy", hint.says);
    try std.testing.expect(names(hint, "Tags"));
    try std.testing.expect(!names(hint, "title"));
    try std.testing.expect(comptime parse("no sentence here") == null);
}
