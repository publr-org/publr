//! The process environment: API keys and the like, set where the process starts, never
//! kept in the database or the repository. Read-only, read when needed, so a restart is
//! all a new value takes.
//!
//! `publr.environment.get` for plugins compiled into Publr. An installed plugin never reads
//! the environment (it is always null there): it declares the secret it needs and is handed
//! it through the gateway.

const std = @import("std");
const builtin = @import("builtin");

pub const name_len_max: u32 = 128;

/// The variable's value; null when unset, empty, or where there is no environment (the
/// browser build).
pub fn get(name: [:0]const u8) ?[]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(name.len <= name_len_max);

    if (!builtin.link_libc) {
        return null;
    }

    const value = std.mem.span(std.c.getenv(name.ptr) orelse return null);

    return if (value.len > 0) value else null;
}

test "an unset variable is null, a set one its value" {
    try std.testing.expect(get("PUBLR_SURELY_UNSET_VARIABLE_1F3A") == null);

    if (builtin.link_libc) {
        try std.testing.expect(get("PATH") != null);
    }
}
