//! Keep tallies of a word and walk them back.
//!
//! Keeps `count` tallies of `word`, then reads them every way a walk reads: all of them a
//! page at a time, the first few, the newest, one left after its first row, and counted
//! from the index, then a page at a time through `leaves`. Administrators may call it.
//!
//! Example:
//!   in: { "word": "pine", "count": 3 }
//!   out: { "walked": 3, "ordered": true, "first_two": 2, "newest": true, "early": 1,
//!     "counted": 3, "kept": true, "paged": 3 }
const publr = @import("publr");
const std = @import("std");
const Tallies = @import("../records/tallies.zig");
const Leaves = @import("leaves.zig");

const Tally = Tallies.Tally;
const Word = struct {
    word: []const u8,
};

pub const In = struct {
    /// The word to keep tallies of
    word: []const u8,
    /// How many to keep, up to 1,000
    count: u32,
};

pub const Out = struct {
    /// The rows a walk over all of them handed out
    walked: u32,
    /// Whether they came in the order they were kept
    ordered: bool,
    /// The rows a walk of the first two handed out
    first_two: u32,
    /// Whether the newest is the one the whole walk ended with
    newest: bool,
    /// The rows a walk left after its first row handed out
    early: u32,
    /// How many there are, counted from the index
    counted: u64,
    /// Whether a list and a map made before the walk kept every id put in them inside it
    kept: bool,
    /// The tallies `leaves` answered, every page of it walked
    paged: u32,
};

const count_max: u32 = 1000;
/// Tallies kept in one call into core: a page.
const batch_max: u32 = 200;

fn run(ctx: *publr.Ctx, in: In) publr.Error!Out {
    std.debug.assert(ctx.now().ms >= 0);

    if (in.count == 0 or in.count > count_max or in.word.len == 0) {
        return error.Invalid;
    }

    try keep(ctx, in);

    var last: [64]u8 = undefined;
    var last_len: u32 = 0;
    var in_order = true;
    var walked: u32 = 0;
    var all = Tallies.record.where(ctx, .word, in.word);
    // Made before the walk: what each turn puts in them stays.
    var ids = publr.List([]const u8).init(ctx);
    var places = publr.IdMap(u32).init(ctx);

    while (try all.next()) |tally| {
        // A turn's own memory: given back at the next row, never piled up.
        _ = ctx.arena().alloc(u8, 4096) catch return error.OutOfMemory;

        in_order = in_order and std.mem.order(u8, last[0..last_len], tally.id) == .lt;
        @memcpy(last[0..tally.id.len], tally.id);
        last_len = @intCast(tally.id.len);

        const id = try all.keep(tally.id);

        try ids.append(id);
        try places.put(id, walked);
        walked += 1;
    }

    const newest = try newest_of(ctx, in.word);

    return .{
        .walked = walked,
        .ordered = in_order,
        .first_two = try walked_of(Tallies.record.where(ctx, .word, in.word).first(2)),
        .newest = std.mem.eql(u8, newest, last[0..last_len]),
        .early = try left_early(ctx, in.word),
        .counted = try Tallies.record.where(ctx, .word, in.word).count(),
        .kept = kept_all(&ids, &places, walked),
        .paged = try paged_of(ctx, in.word),
    };
}

/// The tallies of `word` counted a page of `leaves` at a time, one page held at once.
fn paged_of(ctx: *publr.Ctx, word: []const u8) publr.Error!u32 {
    var pages = publr.pages(ctx, Leaves.operation, .{
        .word = word,
    });
    var counted: u32 = 0;

    while (try pages.next()) |page| {
        counted += @intCast(page.leaves.len);
    }

    std.debug.assert(pages.done);

    return counted;
}

/// Whether every id the walk put in `ids` and `places` is there, in its place.
fn kept_all(ids: *const publr.List([]const u8), places: *const publr.IdMap(u32), walked: u32) bool {
    std.debug.assert(ids.len() <= walked);

    if (ids.len() != walked or places.count() != walked) {
        return false;
    }

    for (ids.items(), 0..) |id, place| {
        if (id.len != 24 or places.get(id) != @as(u32, @intCast(place))) {
            return false;
        }
    }

    return true;
}

/// The tallies kept a page at a time.
fn keep(ctx: *publr.Ctx, in: In) publr.Error!void {
    var values: [batch_max]Tally = undefined;
    var kept: u32 = 0;

    std.debug.assert(in.count <= count_max);

    while (kept < in.count) {
        const batch = @min(in.count - kept, values.len);

        @memset(values[0..batch], .{
            .word = in.word,
        });
        _ = try Tallies.record.create_many(ctx, values[0..batch]);
        kept += batch;
    }
}

fn walked_of(rows: anytype) publr.Error!u32 {
    var walk = rows;
    var walked: u32 = 0;

    while (try walk.next()) |_| {
        walked += 1;
    }

    std.debug.assert(walk.done);

    return walked;
}

/// The newest tally's id, its word alone read.
fn newest_of(ctx: *publr.Ctx, word: []const u8) publr.Error![]const u8 {
    var newest = Tallies.record.where(ctx, .word, word).as(Word).newest().first(1);
    const row = try newest.next() orelse return error.NotFound;
    const id = ctx.arena().dupe(u8, row.id) catch return error.OutOfMemory;

    std.debug.assert(id.len > 0);

    return id;
}

/// A walk left after its first row: its page goes with the call.
fn left_early(ctx: *publr.Ctx, word: []const u8) publr.Error!u32 {
    var walk = Tallies.record.where(ctx, .word, word);
    var walked: u32 = 0;

    while (try walk.next()) |_| {
        walked += 1;

        break;
    }

    std.debug.assert(!walk.done);

    return walked;
}

pub const operation = publr.operation.define(In, Out, .{
    .name = "tally",
    .kind = .write,
    .run = run,
});
