//! A plugin's name as people read it: the words before the colon that opens its `main.zig`'s
//! `//!` (`//! Bank transfer: the buyer pays…` is "Bank transfer"), its name where the first
//! line opens otherwise. English, marked for translators as the summary's own words.
const std = @import("std");

/// The longest label taken from a summary; a longer opening is a sentence, not a name.
pub const label_len_max: u32 = 40;

pub fn of(name: []const u8, summary: []const u8) []const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(summary.len <= 1 << 16);

    const colon = std.mem.indexOf(u8, summary, ": ") orelse return name;
    const opening = std.mem.trim(u8, summary[0..colon], " ");
    const sentence = std.mem.indexOfAny(u8, opening, ".,;\n") != null;

    if (opening.len == 0 or opening.len > label_len_max or sentence) {
        return name;
    }

    return opening;
}

test "a label from the summary's opening words, else the name" {
    try std.testing.expectEqualStrings(
        "Bank transfer",
        of("bank_transfer", "Bank transfer: the buyer pays by transferring what it owes."),
    );
    try std.testing.expectEqualStrings("Polski", of("language_pl", "Polski: the admin in Polish."));
    try std.testing.expectEqualStrings(
        "products",
        of("products", "Products and their variants, each with a price: sold through orders."),
    );
    try std.testing.expectEqualStrings("greeter", of("greeter", "Greetings kept as records"));
    try std.testing.expectEqualStrings("hello", of("hello", ": nothing before it"));
}
