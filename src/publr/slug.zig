//! Text utilities: slugs (URL-safe names) and their numeric suffixes.

const std = @import("std");

pub const slug_len_max: u32 = 200;
pub const attempts_max: u32 = 50;

/// Latin letters with marks, as the plain letters an address spells them with: `Róża` is
/// `roza`, `Straße` is `strasse`. Lowercase and uppercase alike.
const marked_letters = [_][]const u8{
    "ą",
    "Ą",
    "ć",
    "Ć",
    "ę",
    "Ę",
    "ł",
    "Ł",
    "ń",
    "Ń",
    "ó",
    "Ó",
    "ś",
    "Ś",
    "ź",
    "Ź",
    "ż",
    "Ż",
    "á",
    "Á",
    "à",
    "â",
    "ä",
    "Ä",
    "ã",
    "å",
    "č",
    "Č",
    "ç",
    "ď",
    "é",
    "É",
    "è",
    "ê",
    "ë",
    "ě",
    "í",
    "Í",
    "î",
    "ï",
    "ň",
    "ñ",
    "ô",
    "ö",
    "Ö",
    "õ",
    "ø",
    "ř",
    "Ř",
    "š",
    "Š",
    "ť",
    "ú",
    "Ú",
    "ù",
    "û",
    "ü",
    "Ü",
    "ů",
    "ý",
    "ž",
    "Ž",
    "ß",
    "æ",
    "œ",
};
/// Each of `marked_letters` as an address spells it, by position.
const plain_letters = [_][]const u8{
    "a", "a", "c",  "c",  "e",  "e", "l", "l", "n", "n",
    "o", "o", "s",  "s",  "z",  "z", "z", "z", "a", "a",
    "a", "a", "a",  "a",  "a",  "a", "c", "c", "c", "d",
    "e", "e", "e",  "e",  "e",  "e", "i", "i", "i", "i",
    "n", "n", "o",  "o",  "o",  "o", "o", "r", "r", "s",
    "s", "t", "u",  "u",  "u",  "u", "u", "u", "u", "y",
    "z", "z", "ss", "ae", "oe",
};

/// The plain letters `text` starts with when it starts with a marked one, and its length.
fn plain_at(text: []const u8) ?Plain {
    std.debug.assert(text.len > 0);
    comptime std.debug.assert(marked_letters.len == plain_letters.len);

    if (text[0] < 0x80) {
        return null;
    }

    for (marked_letters, plain_letters) |marked, plain| {
        if (std.mem.startsWith(u8, text, marked)) {
            return .{
                .letters = plain,
                .len = @intCast(marked.len),
            };
        }
    }

    return null;
}

const Plain = struct {
    letters: []const u8,
    /// How many bytes the marked letter takes.
    len: u32,
};

pub fn slugify(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    std.debug.assert(slug_len_max > 0);
    std.debug.assert(text.len <= 1 << 20);

    var out: std.ArrayList(u8) = .empty;
    var pending_hyphen = false;
    var index: u32 = 0;

    while (index < text.len) : (index += 1) {
        const char = text[index];
        const lower = std.ascii.toLower(char);

        // An apostrophe joins its word (`Dawid's` is `dawids`), straight or curly (U+2019).
        if (char == '\'') {
            continue;
        }

        if (std.mem.startsWith(u8, text[index..], "\u{2019}")) {
            index += @intCast("\u{2019}".len - 1);
            continue;
        }

        if (plain_at(text[index..])) |found| {
            if (pending_hyphen and out.items.len > 0) {
                try out.append(arena, '-');
            }

            pending_hyphen = false;
            try out.appendSlice(arena, found.letters);
            index += found.len - 1;

            if (out.items.len >= slug_len_max) {
                out.shrinkRetainingCapacity(slug_len_max);
                break;
            }

            continue;
        }

        const keep = (lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9');

        if (keep) {
            if (pending_hyphen and out.items.len > 0) {
                try out.append(arena, '-');
            }

            pending_hyphen = false;
            try out.append(arena, lower);

            if (out.items.len == slug_len_max) {
                break;
            }
        } else {
            pending_hyphen = true;
        }
    }

    if (out.items.len == 0) {
        try out.appendSlice(arena, "record");
    }

    return out.items;
}

pub fn with_suffix(arena: std.mem.Allocator, base: []const u8, attempt: u32) ![]const u8 {
    std.debug.assert(base.len > 0);
    std.debug.assert(attempt >= 2 and attempt <= attempts_max);

    return std.fmt.allocPrint(arena, "{s}-{d}", .{ base, attempt });
}

test "slugify lowers, collapses separators, trims, and never returns empty" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("hello-world", try slugify(arena, "  Hello,   World! "));
    try std.testing.expectEqualStrings("cafe-2024", try slugify(arena, "Café 2024"));
    try std.testing.expectEqualStrings("kwiaciarnia-roza", try slugify(arena, "Kwiaciarnia Róża"));
    try std.testing.expectEqualStrings("zolta-lodz", try slugify(arena, "ŻÓŁTA Łódź"));
    try std.testing.expectEqualStrings("strasse", try slugify(arena, "Straße"));
    try std.testing.expectEqualStrings("record", try slugify(arena, "!!!"));
    try std.testing.expectEqualStrings("dawids-app", try slugify(arena, "Dawid's App"));
    try std.testing.expectEqualStrings("dawids-app", try slugify(arena, "Dawid\u{2019}s App"));
    try std.testing.expectEqualStrings("hello-world-2", try with_suffix(arena, "hello-world", 2));
}
