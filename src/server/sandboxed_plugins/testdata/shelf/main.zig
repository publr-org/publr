//! Items on a shelf, with a count and an event when one comes back.
//!
//! The provider the remote checks are tested with: `shelf.item` records (a title, a SKU),
//! `shelf count` counts them, `shelf restock` says one came back (`shelf.restocked`), and
//! an internal `shelf.bin` keeps how many of an item a bin holds. `labels` needs it as it
//! is; `stocktake` works with it when it fits.
const std = @import("std");
const publr = @import("publr");

const manifest: publr.Manifest = .{
    .name = "shelf",
    .version = "0.1.0",
};

/// Item
///
/// One thing on the shelf.
pub const Item = struct {
    /// Title
    title: []const u8,
    /// SKU
    sku: []const u8 = "",
    /// Note
    note: []const u8 = "",
};

pub const Items = publr.record.define(Item, .{
    .name = "shelf.item",
    .title_field = .title,
});

/// How many of an item one bin holds: the shelf's own bookkeeping.
pub const Bin = struct {
    item: []const u8,
    count: u32,
};

pub const Bins = publr.record.define(Bin, .{
    .name = "shelf.bin",
    .internal = true,
});

pub const Restocked = publr.event.define(.{
    .name = "restocked",
    .payload = struct {
        /// The SKU back in stock
        sku: []const u8,
    },
});

const counted = publr.query.prepare("count(*[_type == \"shelf.item\"])", .{});

pub const CountIn = struct {};

pub const CountOut = struct {
    /// How many items there are
    count: u32,
};

/// Counts the items on the shelf.
///
/// Example:
///   in: {}
///   out: { "count": 1 }
pub const Count = publr.operation.define(CountIn, CountOut, .{
    .name = "count",
    .kind = .read,
    .run = count,
});

fn count(ctx: *publr.Ctx, _: CountIn) publr.Error!CountOut {
    std.debug.assert(ctx.now().ms >= 0);

    const found = try counted.execute(ctx, u32, .{});

    return .{
        .count = found,
    };
}

pub const RestockIn = struct {
    /// The SKU back in stock
    sku: []const u8,
};

pub const RestockOut = struct {
    /// Whether the event went out
    told: bool,
};

/// Says an item is back in stock: emits `shelf.restocked`.
///
/// Example:
///   in: { "sku": "A-1" }
///   out: { "told": true }
pub const Restock = publr.operation.define(RestockIn, RestockOut, .{
    .name = "restock",
    .kind = .write,
    .run = restock,
});

fn restock(ctx: *publr.Ctx, in: RestockIn) publr.Error!RestockOut {
    std.debug.assert(ctx.now().ms >= 0);

    if (in.sku.len == 0 or in.sku.len > 64) {
        return error.Invalid;
    }

    ctx.emit(Restocked, .{
        .sku = in.sku,
    });

    return .{
        .told = true,
    };
}

pub const plugin = publr.plugin.define(manifest, .{
    .records = &.{ Items, Bins },
    .operations = &.{ Count, Restock },
    .events = &.{Restocked},
});
