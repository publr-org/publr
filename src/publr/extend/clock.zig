//! The wall clock, for a built-in plugin's code outside any call (a route, a process hook):
//! inside one, `ctx.now()` is the call's time.
const std = @import("std");

/// Unix milliseconds now, on `io`'s real clock.
pub fn wall_clock_ms(io: std.Io) i64 {
    const now = std.Io.Clock.real.now(io);
    const ms: i64 = @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_ms));

    std.debug.assert(ms >= 0);
    std.debug.assert(ms < std.math.maxInt(i64) / 2);

    return ms;
}
