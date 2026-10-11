//! What one type and one entry may hold, as this build of Publr was made
//! (`build/limits.zig`, `-Dtype-fields-max` and the others), and every budget that follows
//! from them. Past three quarters of a limit, the admin says how near it is.
const std = @import("std");
const chosen = @import("limits_options");

/// Fields a type holds at one level.
pub const type_fields_max: u32 = chosen.type_fields_max;
/// Values one entry holds, every field and repeater item's together.
pub const entry_values_max: u32 = chosen.entry_values_max;
/// One entry's document, as saved.
pub const entry_bytes_max: u32 = chosen.entry_bytes_max;
/// One request, as it arrives.
pub const request_bytes_max: u32 = chosen.request_bytes_max;

/// An operation's input: an entry, and what goes with it.
pub const input_bytes_max: u32 = entry_bytes_max + (64 << 10);

/// One request's working memory: room for its input many times over (parsed, checked,
/// drawn) and never less than 4 MiB. Measured 2026-10-10: an entry's editor takes about 6 KB
/// of it per value.
pub const request_arena_bytes: u32 = @max(4 << 20, entry_bytes_max * 32);

/// Where the admin starts saying how near a limit is: three quarters of it.
pub fn near(count: u32, limit: u32) bool {
    std.debug.assert(limit > 0);

    return count * 4 >= limit * 3;
}

comptime {
    std.debug.assert(request_bytes_max >= input_bytes_max);
    std.debug.assert(request_arena_bytes >= 4 << 20);
}

test "near a limit is three quarters of it" {
    try std.testing.expect(!near(149, 200));
    try std.testing.expect(near(150, 200));
    try std.testing.expect(near(200, 200));
}
