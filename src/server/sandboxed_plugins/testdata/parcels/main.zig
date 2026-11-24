//! Parcels, quoted by whichever carriers are installed.
//!
//! The owner the published interface checks are tested with: it owns the contract
//! `parcels.carrier` (`interface.zig`), lists its carriers and asks them from the queue where
//! a parcel is (`follow`). `parcel_post` provides it, built against this plugin's published
//! interface; `parcels_next` changes it.
const std = @import("std");
const publr = @import("publr");
const interface = @import("parcels");

const manifest: publr.Manifest = .{
    .name = "parcels",
    .version = "0.1.0",
};

pub const CarriersIn = struct {};

pub const CarriersOut = struct {
    /// Each carrier that is on, in the administrator's order
    carriers: []const []const u8,
};

/// Lists the carriers that quote parcels.
///
/// Example:
///   in: {}
///   out: { "carriers": [] }
pub const Carriers = publr.operation.define(CarriersIn, CarriersOut, .{
    .name = "carriers",
    .kind = .read,
    .run = carriers,
});

fn carriers(ctx: *publr.Ctx, in: CarriersIn) publr.Error!CarriersOut {
    _ = in;

    const found = try publr.providers(ctx, interface.carrier, .{});
    const names = ctx.arena().alloc([]const u8, found.len) catch return error.OutOfMemory;

    std.debug.assert(found.len <= 64);

    for (found, names) |provider, *name| {
        name.* = provider.name();
    }

    return .{
        .carriers = names,
    };
}

pub const FactsIn = struct {};

pub const FactsOut = struct {
    /// What each carrier that is on said it carries when it was installed
    carries: []const []const u8,
};

/// Says what each carrier carries, as it answered when installed.
///
/// Example:
///   in: {}
///   out: { "carries": [] }
pub const Facts = publr.operation.define(FactsIn, FactsOut, .{
    .name = "facts",
    .kind = .read,
    .run = facts,
});

fn facts(ctx: *publr.Ctx, in: FactsIn) publr.Error!FactsOut {
    _ = in;

    const found = try publr.providers(ctx, interface.carrier, .{});
    const carried = ctx.arena().alloc([]const u8, found.len) catch return error.OutOfMemory;

    std.debug.assert(found.len <= 64);

    for (found, carried) |provider, *carries| {
        carries.* = (try provider.answers(ctx)).carries;
    }

    return .{
        .carries = carried,
    };
}

pub const FollowIn = struct {
    /// The parcel's number with its carrier
    number: []const u8,
};

pub const FollowOut = struct {
    /// Whether it is asked after, from the queue
    queued: bool,
};

/// Asks each carrier that tracks where a parcel is, from the queue: tracking is a request
/// out.
///
/// Example:
///   in: { "number": "PP-1" }
///   out: { "queued": true }
pub const Follow = publr.operation.define(FollowIn, FollowOut, .{
    .name = "follow",
    .kind = .write,
    .run = follow,
});

fn follow(ctx: *publr.Ctx, in: FollowIn) publr.Error!FollowOut {
    std.debug.assert(in.number.len > 0);

    try ctx.enqueue(Tracking, in);

    return .{
        .queued = true,
    };
}

pub const Tracking = publr.job.define(FollowIn, .{
    .name = "tracking",
    .run = tracking,
});

/// Each carrier's answer on the Log: where the parcel is, or why it could not say.
fn tracking(ctx: *publr.QueueCtx, in: FollowIn) publr.Error!void {
    std.debug.assert(in.number.len > 0);

    const found = try publr.providers(ctx, interface.carrier, .{});

    for (found) |provider| {
        const part = provider.optional(.track) orelse continue;
        const answer = part.call(ctx, .{
            .number = in.number,
        }) catch |err| {
            ctx.log(.warn, "Not tracked: {s}", .{@errorName(err)});
            continue;
        };

        ctx.log(.info, "Tracked: {s}", .{answer.at});
    }
}

pub const plugin = publr.plugin.define(manifest, .{
    .operations = &.{ Carriers, Facts, Follow },
    .jobs = &.{Tracking},
    .contracts = .{interface.carrier},
});
