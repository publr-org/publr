//! Takes stock of the shelf when there is one.
//!
//! Works with `shelf` (`compatible_with`): counts through `shelf count`, restocks through
//! `shelf restock`, reads items' titles and its bins' counts, and logs each
//! `shelf.restocked`. A remote that no longer fits is off on its own (its call answers
//! unavailable, its hook stays quiet) while the rest keeps working.
const std = @import("std");
const publr = @import("publr");

const manifest: publr.Manifest = .{
    .name = "stocktake",
    .version = "0.1.0",
};

pub const ShelfCount = publr.remote.operation("shelf.count", struct {}, struct {
    count: u32,
});

pub const ShelfRestock = publr.remote.operation("shelf.restock", struct {
    sku: []const u8,
}, struct {
    told: bool,
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

pub const CountManyIn = struct {
    /// How many times to ask
    times: u32,
};

/// Counts the shelf through `shelf count` again and again, in one call: what nested calls
/// cost the call's memory.
///
/// Example:
///   in: { "times": 2 }
///   out: { "count": 0 }
pub const CountMany = publr.operation.define(CountManyIn, TakeOut, .{
    .name = "count_many",
    .kind = .read,
    .run = count_many,
});

fn count_many(ctx: *publr.Ctx, in: CountManyIn) publr.Error!TakeOut {
    std.debug.assert(in.times <= 10_000);

    var counted: u32 = 0;
    var asked: u32 = 0;

    while (asked < in.times) : (asked += 1) {
        counted = (try ctx.call(ShelfCount, .{})).count;
    }

    return .{
        .count = counted,
    };
}

pub const ReadManyIn = struct {
    /// The shelf item, by id
    item: []const u8,
    /// How many times to read it
    times: u32,
};

pub const ReadManyOut = struct {
    /// The item's title
    title: []const u8,
};

/// Reads a shelf item again and again, in one call: what calls to Publr's own operations
/// cost the call's memory.
///
/// Example:
///   in: { "item": "a1b2c3d4e5f60718293a4b5c", "times": 2 }
///   out: { "title": "Tea" }
pub const ReadMany = publr.operation.define(ReadManyIn, ReadManyOut, .{
    .name = "read_many",
    .kind = .read,
    .run = read_many,
});

fn read_many(ctx: *publr.Ctx, in: ReadManyIn) publr.Error!ReadManyOut {
    std.debug.assert(in.times > 0);
    std.debug.assert(in.times <= 10_000);

    var title: []const u8 = "";
    var read: u32 = 0;

    while (read < in.times) : (read += 1) {
        title = (try ShelfItem.get(ctx, in.item, .{})).value.title;
    }

    return .{
        .title = title,
    };
}

pub const PassOnIn = struct {
    /// The SKU back in stock
    sku: []const u8,
};

pub const PassOnOut = struct {
    /// Whether the shelf told
    told: bool,
};

/// Tells the shelf an item came back, through `shelf restock`.
///
/// Example:
///   in: { "sku": "A-1" }
///   out: { "told": true }
pub const PassOn = publr.operation.define(PassOnIn, PassOnOut, .{
    .name = "pass_on",
    .kind = .write,
    .run = pass_on,
});

fn pass_on(ctx: *publr.Ctx, in: PassOnIn) publr.Error!PassOnOut {
    std.debug.assert(in.sku.len > 0);

    const answered = try ctx.call(ShelfRestock, .{
        .sku = in.sku,
    });

    return .{
        .told = answered.told,
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

/// Said once stocktake heard an item is back: an event an `on` hook emits, outside any write.
pub const Noted = publr.event.define(.{
    .name = "noted",
    .payload = struct {
        /// The SKU back in stock
        sku: []const u8,
    },
});

/// Logs each SKU back in stock, and says it noted it (`stocktake.noted`).
fn heard(ctx: *publr.QueueCtx, payload: ShelfRestocked.Payload) publr.Error!void {
    std.debug.assert(payload.sku.len > 0);

    ctx.log(.info, "Back in stock: {s}", .{payload.sku});
    ctx.emit(Noted, .{
        .sku = payload.sku,
    });
}

/// Logs what it noted: heard from its own event, emitted by its other hook.
fn noted(ctx: *publr.QueueCtx, payload: Noted.Payload) publr.Error!void {
    std.debug.assert(payload.sku.len > 0);

    ctx.log(.info, "Noted: {s}", .{payload.sku});
}

pub const plugin = publr.plugin.define(manifest, .{
    .compatible_with = .{"shelf"},
    .remotes = &.{ ShelfCount, ShelfItem, ShelfRestocked, ShelfBin, ShelfRestock },
    .operations = &.{ Take, CountMany, ReadMany, PassOn, Note },
    .hooks = &.{
        publr.on(ShelfRestocked, heard),
        publr.on(Noted, noted),
    },
    .events = &.{Noted},
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
        .{
            .key = "call:shelf.restock",
            .reason = "Tells the shelf an item came back",
        },
    },
});
