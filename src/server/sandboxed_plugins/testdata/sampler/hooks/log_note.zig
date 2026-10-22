const publr = @import("publr");
const std = @import("std");

const Logs = @import("../records/logs.zig");
const Noted = @import("../events/noted.zig");

/// Logs every note kept
pub fn run(ctx: *publr.Ctx, noted: Noted.Payload) publr.Error!void {
    std.debug.assert(noted.note.len > 0);
    std.debug.assert(noted.note.len <= 280);

    _ = try Logs.typed.create(ctx, .{
        .line = try ctx.print("noted {s}", .{noted.note}),
    }, .{});
    ctx.log(.info, "on sampler.noted, from the queue: wrote the log line noted {s}", .{noted.note});
}
