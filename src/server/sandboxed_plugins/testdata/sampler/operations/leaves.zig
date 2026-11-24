//! A word's tallies, a page at a time.
//!
//! The tallies kept of `word`, in the order they were kept, 200 a page: `after` takes the
//! `next` the page before answered. Administrators may call it.
//!
//! Example:
//!   in: { "word": "pine" }
//!   out: { "leaves": [], "next": "" }
const publr = @import("publr");
const std = @import("std");
const Tallies = @import("../records/tallies.zig");

pub const In = struct {
    /// The word whose tallies to list
    word: []const u8,
    /// The page after this tally: the `next` the last page answered
    after: []const u8 = "",
};

pub const Leaf = struct {
    /// The tally's id
    id: []const u8,
};

pub const Out = struct {
    /// The page's tallies, oldest first
    leaves: []const Leaf,
    /// The next page's `after`; empty after the last
    next: []const u8 = "",
};

fn run(ctx: *publr.Ctx, in: In) publr.Error!Out {
    std.debug.assert(ctx.now().ms >= 0);

    if (in.word.len == 0) {
        return error.Invalid;
    }

    const page = try Tallies.record.where(ctx, .word, in.word).page_after(in.after);
    const leaves = ctx.arena().alloc(Leaf, page.rows.len) catch return error.OutOfMemory;

    for (page.rows, leaves) |row, *leaf| {
        leaf.* = .{
            .id = row.id,
        };
    }

    return .{
        .leaves = leaves,
        .next = page.next,
    };
}

pub const operation = publr.operation.define(In, Out, .{
    .name = "leaves",
    .kind = .read,
    .run = run,
});
