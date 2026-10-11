//! A turn's last sign of life (a step, a word streamed), watched from a thread of its own:
//! silence past `silence_ms_max` ends the worker, whose supervisor then fails the
//! conversation. A provider that stops answering mid-reply never holds a turn forever.

const std = @import("std");
const sdk = @import("../../sdk.zig");

/// Silence a turn may keep, at most: every provider streams its words, and every call has a
/// time limit, so a turn this quiet is stuck.
pub const silence_ms_max: i64 = 5 * 60 * 1000;
/// What the worker exits with when it fell silent.
pub const exit_code: u8 = 3;
const look_every_s: i64 = 15;

pub const Watchdog = struct {
    io: std.Io,
    last_ms: std.atomic.Value(i64) = .init(0),

    pub fn start(watchdog: *Watchdog) !void {
        std.debug.assert(silence_ms_max > 0);

        watchdog.alive();

        const thread = try std.Thread.spawn(.{}, watch, .{watchdog});

        thread.detach();
    }

    /// Something happened: the turn is alive.
    pub fn alive(watchdog: *Watchdog) void {
        std.debug.assert(look_every_s > 0);

        watchdog.last_ms.store(sdk.context.wall_clock_ms(watchdog.io), .monotonic);
    }

    fn watch(watchdog: *Watchdog) void {
        std.debug.assert(exit_code > 1);

        while (true) {
            std.Io.sleep(watchdog.io, .fromSeconds(look_every_s), .awake) catch return;

            const now_ms = sdk.context.wall_clock_ms(watchdog.io);
            const silent_ms = now_ms - watchdog.last_ms.load(.monotonic);

            if (silent_ms > silence_ms_max) {
                const silent_s = @divTrunc(silent_ms, 1000);

                std.log.err("the turn has been silent for {d} s: ending it", .{silent_s});
                std.process.exit(exit_code);
            }
        }
    }
};
