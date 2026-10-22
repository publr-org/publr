//! Sends a request out, later.
//!
//! The next version of `courier`, as tests and the domains smoke update to it: it no longer
//! asks for api.example.com and asks for localhost instead, so the update review shows the
//! new domain and applying it leaves the administrator's own additions in place.
const std = @import("std");
const publr = @import("publr");

const manifest: publr.Manifest = .{
    .name = "courier",
    .version = "0.2.0",
};

pub const SendIn = struct {
    /// The address to send a GET to
    url: []const u8,
};

pub const SendOut = struct {
    /// Whether the job was queued
    queued: bool,
};

/// Queues a GET of an address, sent by a job.
///
/// Example:
///   in: { "url": "https://api.example.com/ping" }
///   out: { "queued": true }
pub const Send = publr.operation.define(SendIn, SendOut, .{
    .name = "send",
    .kind = .write,
    .run = send,
});

fn send(ctx: *publr.Ctx, in: SendIn) publr.Error!SendOut {
    std.debug.assert(ctx.now().ms >= 0);

    if (in.url.len == 0 or in.url.len > 2048) {
        return error.Invalid;
    }

    try ctx.enqueue(Deliver, .{
        .url = in.url,
    });

    return .{
        .queued = true,
    };
}

pub const ReachIn = struct {};

pub const ReachOut = struct {
    /// The domains its http.fetch grant lists now
    domains: []const []const u8,
};

/// Where it may send requests now, as granted.
///
/// Example:
///   in: {}
///   out: { "domains": ["api.example.com"] }
pub const Reach = publr.operation.define(ReachIn, ReachOut, .{
    .name = "reach",
    .kind = .read,
    .run = reach,
});

fn reach(ctx: *publr.Ctx, in: ReachIn) publr.Error!ReachOut {
    _ = in;
    std.debug.assert(ctx.now().ms >= 0);

    return .{
        .domains = ctx.grant("http.fetch").domains,
    };
}

/// Sends the GET; what it answered, or why it did not go, is logged.
pub const Deliver = publr.job.define(SendIn, .{
    .name = "deliver",
    .run = deliver,
});

fn deliver(ctx: *publr.QueueCtx, in: SendIn) publr.Error!void {
    std.debug.assert(in.url.len > 0);
    std.debug.assert(ctx.now().ms >= 0);

    const answer = ctx.fetch(.{
        .url = in.url,
    }) catch |err| {
        ctx.log(.warn, "Not delivered: {s}", .{@errorName(err)});
        return;
    };

    ctx.log(.info, "Delivered: {d}", .{answer.status});
}

pub const plugin = publr.plugin.define(manifest, .{
    .operations = &.{ Send, Reach },
    .jobs = &.{Deliver},
    .permissions = &.{.{
        .key = "http.fetch",
        .domains = &.{"localhost"},
        .reason = "Sends the requests it is asked to",
    }},
});
