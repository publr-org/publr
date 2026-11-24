//! Keep a basket of a word and watch its size follow the tallies.
//!
//! Keeps a basket of `word`, whose size core works out (the word's tallies counted, its
//! letters, a bonus a modifier adds) and stores. Reads it, keeps one more tally of the
//! word, reads it again: the size has followed. Then saves the basket with a size of its
//! own, which is not kept. Keeps one more tally and adds the sizes up in core. Administrators
//! may call it.
//!
//! Example:
//!   in: { "word": "fern" }
//!   out: { "kept": 0, "after_tally": 1, "letters": 4, "bonus": 7, "saved": 1, "summed": 2 }
const publr = @import("publr");
const std = @import("std");
const Baskets = @import("../records/baskets.zig");
const Tallies = @import("../records/tallies.zig");

pub const In = struct {
    /// The word to keep a basket of
    word: []const u8,
};

pub const Out = struct {
    /// The tallies its size counted when it was kept
    kept: u64,
    /// The tallies its size counted after one more was kept
    after_tally: u64,
    /// The word's letters, as its size has them
    letters: u32,
    /// What the modifier added
    bonus: u32,
    /// The tallies its size counted after a save that sent a size of its own
    saved: u64,
    /// Every basket of the word's tallies added up by core, after one more tally
    summed: i64,
};

fn run(ctx: *publr.Ctx, in: In) publr.Error!Out {
    std.debug.assert(ctx.now().ms >= 0);

    if (in.word.len == 0 or in.word.len > 64) {
        return error.Invalid;
    }

    const id = try Baskets.record.create(ctx, .{
        .word = in.word,
    });
    const kept = try Baskets.record.get(ctx, id, .{});

    _ = try Tallies.record.create(ctx, .{
        .word = in.word,
    });

    const after_tally = try Baskets.record.get(ctx, id, .{});
    var sent = after_tally.value.size;

    sent.tallies = 1000;
    try Baskets.record.save(ctx, after_tally, .{
        .size = sent,
    });

    const saved = try Baskets.record.get(ctx, id, .{});

    _ = try Tallies.record.create(ctx, .{
        .word = in.word,
    });

    const summed = try Baskets.record.where(ctx, .word, in.word).sum("size.tallies");

    return .{
        .kept = kept.value.size.tallies,
        .after_tally = after_tally.value.size.tallies,
        .letters = after_tally.value.size.letters,
        .bonus = after_tally.value.size.bonus,
        .saved = saved.value.size.tallies,
        .summed = summed,
    };
}

pub const operation = publr.operation.define(In, Out, .{
    .name = "basket",
    .kind = .write,
    .run = run,
});
