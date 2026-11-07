//! Parcels, 0.2.0: every carrier prints labels now.
//!
//! The next version of `parcels`, uploaded as its update: `parcels.carrier` requires a
//! `label` part. `parcel_post`, which answers only `quote`, no longer fits it.
const std = @import("std");
const publr = @import("publr");
// Built from a folder of another name, its own interface is imported by path.
const interface = @import("interface.zig");

const manifest: publr.Manifest = .{
    .name = "parcels",
    .version = "0.2.0",
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
