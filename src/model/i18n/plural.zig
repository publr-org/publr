//! Which of a message's plural forms a count takes, in gettext's order (`msgstr[0]`,
//! `msgstr[1]`, ...), by language: CLDR's integer rules, the same table the browser has.
//! A PO file's `Plural-Forms` header is checked against it, never evaluated.
const std = @import("std");

pub const Rule = enum {
    /// `1 file`, `2 files`: English, German, Dutch, the Nordic languages, Spanish, Italian...
    one_other,
    /// `0 fichier`, `1 fichier`, `2 fichiers`: French, Brazilian Portuguese.
    zero_one_other,
    /// One form for every count: Chinese, Japanese, Korean, Thai, Vietnamese, Indonesian.
    single,
    /// `1 plik`, `2 pliki`, `5 plików`.
    polish,
    /// `1 файл`, `2 файла`, `5 файлов`, and `21 файл`: Russian, Ukrainian, Belarusian,
    /// Serbian, Croatian, Bosnian.
    east_slavic,
    /// `1 soubor`, `2 soubory`, `5 souborů`: Czech, Slovak.
    czech,
    /// `1`, `2`, `3`-`4`, the rest, by the last two digits: Slovenian.
    slovenian,
    lithuanian,
    latvian,
    romanian,
    arabic,
};

const Entry = struct {
    language: []const u8,
    rule: Rule,
};

const by_language = [_]Entry{
    .{
        .language = "fr",
        .rule = .zero_one_other,
    },
    .{
        .language = "pt-br",
        .rule = .zero_one_other,
    },
    .{
        .language = "zh",
        .rule = .single,
    },
    .{
        .language = "ja",
        .rule = .single,
    },
    .{
        .language = "ko",
        .rule = .single,
    },
    .{
        .language = "th",
        .rule = .single,
    },
    .{
        .language = "vi",
        .rule = .single,
    },
    .{
        .language = "id",
        .rule = .single,
    },
    .{
        .language = "pl",
        .rule = .polish,
    },
    .{
        .language = "ru",
        .rule = .east_slavic,
    },
    .{
        .language = "uk",
        .rule = .east_slavic,
    },
    .{
        .language = "be",
        .rule = .east_slavic,
    },
    .{
        .language = "sr",
        .rule = .east_slavic,
    },
    .{
        .language = "hr",
        .rule = .east_slavic,
    },
    .{
        .language = "bs",
        .rule = .east_slavic,
    },
    .{
        .language = "cs",
        .rule = .czech,
    },
    .{
        .language = "sk",
        .rule = .czech,
    },
    .{
        .language = "sl",
        .rule = .slovenian,
    },
    .{
        .language = "lt",
        .rule = .lithuanian,
    },
    .{
        .language = "lv",
        .rule = .latvian,
    },
    .{
        .language = "ro",
        .rule = .romanian,
    },
    .{
        .language = "ar",
        .rule = .arabic,
    },
};

/// The rule a language takes: its own code (`pt-br`), else its language without the region
/// (`pl-pl` is `pl`), else one and other.
pub fn rule_of(locale: []const u8) Rule {
    std.debug.assert(locale.len <= 64);
    std.debug.assert(by_language.len > 0);

    const dash = std.mem.indexOfScalar(u8, locale, '-') orelse locale.len;
    const candidates = [_][]const u8{ locale, locale[0..dash] };

    for (candidates) |candidate| {
        for (by_language) |entry| {
            if (std.mem.eql(u8, entry.language, candidate)) {
                return entry.rule;
            }
        }
    }

    return .one_other;
}

/// How many forms a message has in a language taking `rule`: `nplurals`.
pub fn forms(rule: Rule) u32 {
    const count: u32 = switch (rule) {
        .single => 1,
        .one_other, .zero_one_other => 2,
        .polish, .east_slavic, .czech, .lithuanian, .latvian, .romanian => 3,
        .slovenian => 4,
        .arabic => 6,
    };

    std.debug.assert(count >= 1 and count <= 6);

    return count;
}

/// The form a count takes, `0` to `forms(rule) - 1`. A fraction takes the last form.
pub fn index(rule: Rule, count: f64) u32 {
    std.debug.assert(forms(rule) >= 1);

    if (count < 0 or count != @floor(count) or count > 1e15) {
        return forms(rule) - 1;
    }

    const number: u64 = @intFromFloat(count);
    const form = integer_index(rule, number);

    std.debug.assert(form < forms(rule));

    return form;
}

fn integer_index(rule: Rule, number: u64) u32 {
    std.debug.assert(number <= 1_000_000_000_000_000);

    const last = number % 10;
    const two = number % 100;
    const few = last >= 2 and last <= 4 and (two < 12 or two > 14);

    return switch (rule) {
        .single => 0,
        .one_other => if (number == 1) 0 else 1,
        .zero_one_other => if (number <= 1) 0 else 1,
        .polish => if (number == 1) 0 else if (few) 1 else 2,
        .east_slavic => if (last == 1 and two != 11) 0 else if (few) 1 else 2,
        .czech => if (number == 1) 0 else if (number >= 2 and number <= 4) 1 else 2,
        .slovenian => if (two == 1) 0 else if (two == 2) 1 else if (two == 3 or two == 4) 2 else 3,
        .lithuanian => if (last == 1 and (two < 11 or two > 19))
            0
        else if (last >= 2 and (two < 11 or two > 19)) 1 else 2,
        .latvian => if (last == 1 and two != 11) 0 else if (number != 0) 1 else 2,
        .romanian => if (number == 1) 0 else if (number == 0 or (two >= 1 and two <= 19)) 1 else 2,
        .arabic => if (number <= 2)
            @intCast(number)
        else if (two >= 3 and two <= 10) 3 else if (two >= 11) 4 else 5,
    };
}

test "Polish: one, few, many" {
    try std.testing.expectEqual(@as(u32, 0), index(.polish, 1));
    try std.testing.expectEqual(@as(u32, 1), index(.polish, 2));
    try std.testing.expectEqual(@as(u32, 1), index(.polish, 24));
    try std.testing.expectEqual(@as(u32, 2), index(.polish, 5));
    try std.testing.expectEqual(@as(u32, 2), index(.polish, 12));
    try std.testing.expectEqual(@as(u32, 2), index(.polish, 21));
    try std.testing.expectEqual(@as(u32, 2), index(.polish, 0));
    try std.testing.expectEqual(@as(u32, 2), index(.polish, 1.5));
    try std.testing.expectEqual(@as(u32, 3), forms(.polish));
}

test "languages by code, region dropped, English-like by default" {
    try std.testing.expectEqual(Rule.polish, rule_of("pl"));
    try std.testing.expectEqual(Rule.polish, rule_of("pl-pl"));
    try std.testing.expectEqual(Rule.zero_one_other, rule_of("pt-br"));
    try std.testing.expectEqual(Rule.one_other, rule_of("pt"));
    try std.testing.expectEqual(Rule.one_other, rule_of("en-gb"));
    try std.testing.expectEqual(@as(u32, 0), index(.east_slavic, 21));
    try std.testing.expectEqual(@as(u32, 2), index(.east_slavic, 11));
    try std.testing.expectEqual(@as(u32, 0), index(.zero_one_other, 0));
    try std.testing.expectEqual(@as(u32, 0), index(.single, 7));
}
