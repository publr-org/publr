//! A device: an agent or a tool a person let act for their account, under a scope. What it
//! may be called, which scopes there are, and the short code a person types to approve it.

const std = @import("std");

pub const name_len_max: u32 = 80;
/// How long a person has to approve a device once it asked.
pub const request_lifetime_ms: i64 = 10 * std.time.ms_per_min;
/// How often a waiting device asks again.
pub const poll_interval_s: u32 = 3;
/// `WXYZ-1234`: two groups of four, letters a person cannot misread for another.
pub const user_code_len: u32 = 9;
pub const user_code_alphabet = "BCDFGHJKLMNPQRSTVWXZ";

/// What a device may do with its account: read only; write, but nothing visitors see
/// changes (edits wait as drafts for a person); or everything the account may.
pub const Scope = enum {
    read,
    drafts,
    write,

    pub fn parse(text: []const u8) ?Scope {
        std.debug.assert(text.len <= 1 << 16);

        return std.meta.stringToEnum(Scope, text);
    }

    /// Whether `scope` gives no more than `limit`.
    pub fn within(scope: Scope, limit: Scope) bool {
        const narrower = @intFromEnum(scope) <= @intFromEnum(limit);

        std.debug.assert(narrower or scope != .read);

        return narrower;
    }
};

/// A name a person reads on the approve page: 1 to 80 characters, no control characters.
pub fn valid_name(name: []const u8) bool {
    std.debug.assert(name_len_max > 0);

    if (name.len == 0 or name.len > name_len_max) {
        return false;
    }

    for (name) |char| {
        if (char < 0x20 or char == 0x7f) {
            return false;
        }
    }

    return std.unicode.utf8ValidateSlice(name);
}

/// The code a person types, made from random bytes: `XXXX-XXXX`.
pub fn user_code(random: [8]u8) [user_code_len]u8 {
    std.debug.assert(user_code_alphabet.len == 20);

    var code: [user_code_len]u8 = undefined;
    var index: u32 = 0;

    for (random) |byte| {
        if (index == 4) {
            code[index] = '-';
            index += 1;
        }

        code[index] = user_code_alphabet[byte % user_code_alphabet.len];
        index += 1;
    }

    std.debug.assert(index == user_code_len);

    return code;
}

/// A code as a person typed it: any case, with or without the dash or spaces. Null when it
/// cannot be one.
pub fn normalize_user_code(text: []const u8) ?[user_code_len]u8 {
    if (text.len > 32) {
        return null;
    }

    var letters: [8]u8 = undefined;
    var count: u32 = 0;

    for (text) |char| {
        if (char == '-' or char == ' ') {
            continue;
        }

        const upper = std.ascii.toUpper(char);

        if (count == 8 or std.mem.indexOfScalar(u8, user_code_alphabet, upper) == null) {
            return null;
        }

        letters[count] = upper;
        count += 1;
    }

    if (count != 8) {
        return null;
    }

    std.debug.assert(count == letters.len);

    return (letters[0..4] ++ "-" ++ letters[4..8]).*;
}

test "scopes order read, drafts, write" {
    try std.testing.expectEqual(Scope.drafts, Scope.parse("drafts").?);
    try std.testing.expect(Scope.parse("admin") == null);
    try std.testing.expect(Scope.read.within(.drafts));
    try std.testing.expect(Scope.drafts.within(.drafts));
    try std.testing.expect(!Scope.write.within(.drafts));
}

test "names: printable, bounded" {
    try std.testing.expect(valid_name("An agent on Ada's laptop"));
    try std.testing.expect(!valid_name(""));
    try std.testing.expect(!valid_name("tab\there"));
    try std.testing.expect(!valid_name("x" ** 81));
    try std.testing.expect(!valid_name("\xff"));
}

test "user codes: made from the alphabet, typed back in any form" {
    const code = user_code(.{ 0, 1, 2, 3, 19, 20, 21, 255 });

    try std.testing.expectEqualStrings("BCDF-ZBCT", &code);
    try std.testing.expectEqualStrings("BCDF-ZBCT", &normalize_user_code("bcdf zbct").?);
    try std.testing.expectEqualStrings("BCDF-ZBCT", &normalize_user_code("BCDFZBCT").?);
    try std.testing.expect(normalize_user_code("BCDF-ZBC") == null);
    try std.testing.expect(normalize_user_code("BCDF-ZBCA") == null);
    try std.testing.expect(normalize_user_code("BCDF-ZBCTN") == null);
}
