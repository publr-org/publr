//! How hard the model thinks this turn, from the ask alone: a site to build like another,
//! or moved over, gets the most; a small change (a short follow-up, a short ask to rename,
//! change or fix something) the least, so it is near instant; anything else the model's
//! own default. Deliberately plain: the eval set says when to change it.

const std = @import("std");

/// A follow-up shorter than this is a small change ("rename it", "jednak Kontakt").
const short_len_max: u32 = 200;

/// `high`, `low`, or empty for the model's default.
pub fn effort_of(prompt: []const u8, follow_up: bool) []const u8 {
    std.debug.assert(prompt.len > 0);
    std.debug.assert(short_len_max > 0);

    var buffer: [4096]u8 = undefined;
    const length = @min(prompt.len, buffer.len);
    const lower = std.ascii.lowerString(buffer[0..length], prompt[0..length]);
    const heavy = [_][]const u8{ "http://", "https://", "migrat", "1:1", "przenie", "skopiuj" };

    for (heavy) |word| {
        if (std.mem.indexOf(u8, lower, word) != null) {
            return "high";
        }
    }

    if (follow_up and prompt.len < short_len_max) {
        return "low";
    }

    const small = [_][]const u8{
        "rename", "change",       "update", "fix", "replace", "remove",
        "zmień",
        "zmien",  "popraw",
        "usuń",
        "usun",   "dodaj rekord", "set ",
    };

    if (prompt.len < short_len_max / 2) {
        for (small) |word| {
            if (std.mem.indexOf(u8, lower, word) != null) {
                return "low";
            }
        }
    }

    return "";
}

test "a site to move or copy thinks hard, a short follow-up moderately" {
    const expect = std.testing.expectEqualStrings;

    try expect("high", effort_of("Migrate https://wagmatik.pl/ 1:1", false));
    try expect("high", effort_of("Przenieś stronę", true));
    try expect("low", effort_of("Zmieniłem zdanie, jednak kontakt", true));
    try expect("low", effort_of("Rename the Kontakt page", false));
    try expect("", effort_of("Add a recipes section", false));
}
