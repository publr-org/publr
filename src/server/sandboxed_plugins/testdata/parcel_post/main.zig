//! Parcel Post, a carrier for parcels.
//!
//! A provider of another plugin's contract: it needs `parcels` and provides its
//! `parcels.carrier`, built against parcels' published interface (`@import("parcels")`)
//! without its code. It answers `quote` only, so parcels 0.2.0, which requires `label`,
//! stops its update. Its `track` asks the carrier's page, a request out: parcels calls it
//! from queued work.
const std = @import("std");
const publr = @import("publr");
const parcels = @import("parcels");

const manifest: publr.Manifest = .{
    .name = "parcel_post",
    .version = "0.1.0",
};

pub const QuoteIn = struct {
    /// How heavy the parcel is
    grams: u32,
};

pub const QuoteOut = struct {
    /// How many days it takes to arrive
    days: u32,
};

/// Quotes a parcel: a day, and one more past five kilograms.
///
/// Example:
///   in: { "grams": 6500 }
///   out: { "days": 2 }
pub const Quote = publr.operation.define(QuoteIn, QuoteOut, .{
    .name = "quote",
    .kind = .read,
    .run = quote,
});

fn quote(ctx: *publr.Ctx, in: QuoteIn) publr.Error!QuoteOut {
    std.debug.assert(ctx.now().ms >= 0);

    if (in.grams == 0 or in.grams > 30_000) {
        return error.Invalid;
    }

    return .{
        .days = if (in.grams > 5000) 2 else 1,
    };
}

pub const FactsIn = struct {};

pub const FactsOut = struct {
    /// What the carrier carries
    carries: []const u8,
};

/// Says what Parcel Post carries: asked once, when it is installed.
///
/// Example:
///   in: {}
///   out: { "carries": "parcels up to 30 kg" }
pub const Facts = publr.operation.define(FactsIn, FactsOut, .{
    .name = "facts",
    .kind = .read,
    .run = facts,
});

fn facts(ctx: *publr.Ctx, in: FactsIn) publr.Error!FactsOut {
    _ = in;
    std.debug.assert(ctx.now().ms >= 0);

    return .{
        .carries = "parcels up to 30 kg",
    };
}

pub const TrackIn = struct {
    /// The carrier's parcel number: here, the address of its tracking page
    number: []const u8,
};

pub const TrackOut = struct {
    /// Where the parcel is now
    at: []const u8,
};

/// Asks the carrier where a parcel is: a request out, so only from queued work.
///
/// Example:
///   in: { "number": "https://localhost/track" }
///   out: { "at": "answered 200" }
pub const Track = publr.operation.define(TrackIn, TrackOut, .{
    .name = "track",
    .kind = .read,
    .run = track,
});

fn track(ctx: *publr.Ctx, in: TrackIn) publr.Error!TrackOut {
    std.debug.assert(in.number.len > 0);

    const answer = try ctx.call(publr.operations.http.Fetch, .{
        .url = in.number,
    });
    const at = std.fmt.allocPrint(ctx.arena(), "answered {d}", .{answer.status}) catch
        return error.OutOfMemory;

    return .{
        .at = at,
    };
}

pub const plugin = publr.plugin.define(manifest, .{
    .depends_on = .{"parcels"},
    .operations = &.{ Quote, Facts, Track },
    .permissions = &.{.{
        .key = "http.fetch",
        .domains = &.{"localhost"},
        .reason = "Asks the carrier where a parcel is",
    }},
    .register_providers = .{.{
        .contract = parcels.contracts.carrier,
        .name = "parcel_post",
        .operations = .{
            .facts = Facts,
            .quote = Quote,
            .track = Track,
        },
    }},
});
