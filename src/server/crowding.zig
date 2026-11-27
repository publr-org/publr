const std = @import("std");
const report = @import("../lib/report.zig");

/// The most often a full server says so.
pub const said_every_ms: i64 = 60 * std.time.ms_per_s;

/// Says when every connection was taken and new ones had to wait in the kernel's queue
/// (`paused_total` grew), at most once a minute, with how many times since it last said.
pub const Crowding = struct {
    connections_max: u32,
    seen: u64 = 0,
    said_ms: i64 = 0,

    pub fn tick(crowding: *Crowding, paused_total: u64, now_ms: i64) void {
        std.debug.assert(paused_total >= crowding.seen);
        std.debug.assert(crowding.connections_max > 0);

        if (paused_total == crowding.seen) {
            return;
        }

        if (crowding.said_ms > 0 and now_ms - crowding.said_ms < said_every_ms) {
            return;
        }

        report.warn_reason(
            "new connections waited until one closed",
            "publr: all {d} connections were open {d} time(s)",
            .{ crowding.connections_max, paused_total - crowding.seen },
        );

        crowding.seen = paused_total;
        crowding.said_ms = now_ms;
    }
};

test "a full server says so once a minute, counting the times in between" {
    // Saying so is what this checks: its warning is expected.
    std.testing.log_level = .err;

    var crowding: Crowding = .{
        .connections_max = 4096,
    };

    crowding.tick(0, 1_000);
    try std.testing.expectEqual(@as(u64, 0), crowding.seen);

    crowding.tick(2, 2_000);
    try std.testing.expectEqual(@as(u64, 2), crowding.seen);
    try std.testing.expectEqual(@as(i64, 2_000), crowding.said_ms);

    crowding.tick(5, 30_000);
    try std.testing.expectEqual(@as(u64, 2), crowding.seen);

    crowding.tick(5, 2_000 + said_every_ms);
    try std.testing.expectEqual(@as(u64, 5), crowding.seen);
}

/// Says once, at startup, when the open-file limit allowed fewer connections than asked.
pub fn say_fitted(asked: u32, served: u32) void {
    std.debug.assert(served > 0);
    std.debug.assert(served <= asked);

    if (served == asked) {
        return;
    }

    report.warn_reason(
        "raise the open-file limit (ulimit -n) for more",
        "publr: serving {d} connections at once, not {d}: the open-file limit allows no more",
        .{ served, asked },
    );
}
