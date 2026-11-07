//! Parcel Post, a carrier for parcels.
//!
//! A provider of another plugin's contract: it needs `parcels` and provides its
//! `parcels.carrier`, built against parcels' published interface (`@import("parcels")`)
//! without its code. It answers `quote` only, so parcels 0.2.0, which requires `label`,
//! stops its update.
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

pub const plugin = publr.plugin.define(manifest, .{
    .depends_on = .{"parcels"},
    .operations = &.{Quote},
    .register_providers = .{.{
        .contract = parcels.contracts.carrier,
        .name = "parcel_post",
        .operations = .{
            .quote = Quote,
        },
    }},
});
