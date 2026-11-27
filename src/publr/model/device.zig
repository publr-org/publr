//! What a device's sign-in keeps to: the name it shows its person, how long a request waits
//! and how often the device asks again.

/// The most characters a device's name has.
pub const name_len_max: u32 = 80;
/// How long a request waits for its person before it lapses.
pub const request_lifetime_ms: i64 = 10 * 60 * 1000;
/// How often a device asks whether its person decided.
pub const poll_interval_s: u32 = 3;

const std = @import("std");

/// What a device may do with its account, each giving what the last did and more: `read`;
/// `write`, on copies of the site, publishing there included (a site without copies has only
/// itself: there edits wait as drafts for a person); `production`, on the site itself too,
/// edits waiting as drafts; `publish`, everything the account may.
pub const Scope = enum {
    read,
    write,
    production,
    publish,

    pub fn parse(text: []const u8) ?Scope {
        std.debug.assert(text.len <= 1 << 16);

        return std.meta.stringToEnum(Scope, text);
    }

    /// Whether `scope` gives no more than `limit`.
    pub fn within(scope: Scope, limit: Scope) bool {
        const narrower = @backingInt(scope) <= @backingInt(limit);

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
