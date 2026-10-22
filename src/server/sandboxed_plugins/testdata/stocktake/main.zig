//! Takes stock of the shelf when there is one.
//!
//! Works with `shelf` (`compatible_with`): counts through `shelf count`, reads items'
//! titles and its bins' counts, and logs each `shelf.restocked`. A remote that no longer
//! fits is off on its own (its call answers unavailable, its hook stays quiet) while the
//! rest keeps working.
const std = @import("std");
const publr = @import("publr");

const manifest: publr.Manifest = .{
    .name = "stocktake",
    .version = "0.1.0",
};

pub const ShelfCount = publr.remote.operation("shelf.count", struct {}, struct {
    count: u32,
});

/// A shelf item as stocktake reads it: only its title.
pub const ShelfItem = publr.remote.record("shelf.item", struct {
    title: []const u8,
});

/// A bin of shelf's own (an internal record), as stocktake reads it: its count.
pub const ShelfBin = publr.remote.record("shelf.bin", struct {
    count: u32,
});

pub const ShelfRestocked = publr.remote.event("shelf.restocked", struct {
    sku: []const u8,
});

pub const TakeIn = struct {};

pub const TakeOut = struct {
    /// How many items the shelf holds
    count: u32,
};

/// Counts the shelf through `shelf count`.
///
/// Example:
///   in: {}
///   out: { "count": 1 }
pub const Take = publr.operation.define(TakeIn, TakeOut, .{
    .name = "take",
    .kind = .read,
    .run = take,
});

fn take(ctx: *publr.Ctx, _: TakeIn) publr.Error!TakeOut {
    std.debug.assert(ctx.now().ms >= 0);

    const counted = try ctx.call(ShelfCount, .{});

    return .{
        .count = counted.count,
    };
}

pub const NoteIn = struct {
    /// What to note
    text: []const u8,
};

pub const NoteOut = struct {
    /// Whether it was noted
    noted: bool,
};

/// Notes something in its log: works whatever the shelf is.
///
/// Example:
///   in: { "text": "Aisle 3 done" }
///   out: { "noted": true }
pub const Note = publr.operation.define(NoteIn, NoteOut, .{
    .name = "note",
    .kind = .write,
    .run = note,
});

fn note(ctx: *publr.Ctx, in: NoteIn) publr.Error!NoteOut {
    std.debug.assert(ctx.now().ms >= 0);

    if (in.text.len == 0 or in.text.len > 200) {
        return error.Invalid;
    }

    ctx.log(.info, "Noted: {s}", .{in.text});

    return .{
        .noted = true,
    };
}

/// Logs each SKU back in stock.
fn heard(ctx: *publr.QueueCtx, payload: ShelfRestocked.Payload) publr.Error!void {
    std.debug.assert(payload.sku.len > 0);

    ctx.log(.info, "Back in stock: {s}", .{payload.sku});
}

pub const plugin = publr.plugin.define(manifest, .{
    .compatible_with = .{"shelf"},
    .remotes = &.{ ShelfCount, ShelfItem, ShelfRestocked, ShelfBin },
    .operations = &.{ Take, Note },
    .hooks = &.{
        publr.on(ShelfRestocked, heard),
    },
    .permissions = &.{
        .{
            .key = "records.read",
            .records = &.{"shelf.item"},
            .reason = "Reads each item's title when it takes stock",
        },
        .{
            .key = "call:shelf.count",
            .reason = "Counts the shelf",
        },
    },
});
