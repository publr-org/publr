//! Parcels, quoted by whichever carriers are installed.
//!
//! The owner the published interface checks are tested with: it owns the contract
//! `parcels.carrier` (`interface.zig`) and lists its carriers. `parcel_post` provides it,
//! built against this plugin's published interface; `parcels_next` changes it.
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

pub const plugin = publr.plugin.define(manifest, .{
    .operations = &.{Carriers},
    .contracts = .{interface.carrier},
});
