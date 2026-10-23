const publr = @import("publr");
const std = @import("std");

/// What the sampler service sends.
pub const Ping = struct {
    /// Its delivery's id
    id: []const u8,
    /// What it says
    text: []const u8,
};

fn run(ctx: *publr.QueueCtx, ping: Ping) publr.Error!void {
    std.debug.assert(ping.id.len > 0);
    std.debug.assert(ctx.now().ms >= 0);

    ctx.log(.info, "webhook ping: {s}", .{ping.text});
}

/// What the sampler service sends to `/_webhooks/sampler.ping`, signed with the sampler key
/// in a header; a delivery sent twice runs once.
pub const webhook = publr.webhook.define(Ping, .{
    .name = "ping",
    .secret = "SAMPLER_KEY",
    .signature = .{
        .token = .{
            .header = "X-Sampler-Key",
        },
    },
    .delivery_id = .{
        .field = "id",
    },
    .run = run,
});
