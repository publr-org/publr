const publr = @import("publr");
const std = @import("std");
const Tallies = @import("tallies.zig");

pub const Basket = struct {
    word: []const u8,
    /// Size: worked out by `sized`, stored with the basket
    size: Size = .{},
};

pub const Size = struct {
    /// How many tallies of the word there are
    tallies: u64 = 0,
    /// The word's letters
    letters: u32 = 0,
    /// Added by the modifier of `sampler.basket.size`
    bonus: u32 = 0,
};

pub const record = publr.record.define(Basket, .{
    .name = "sampler.basket",
    .internal = true,
    .indexed = &.{.word},
    .fields = .{
        .size = .{
            .kind = "virtual",
            .options = .{
                .virtual = .{
                    .computed = sized,
                },
            },
        },
    },
});

/// Counts the basket's word among the tallies.
fn sized(ctx: *publr.Ctx, basket: *const Basket) publr.Error!Size {
    std.debug.assert(basket.word.len > 0);
    std.debug.assert(basket.word.len <= 64);

    const tallies = Tallies.record.where(ctx, .word, basket.word);

    // Counted again tomorrow whatever else happens.
    try ctx.holds_until(.{
        .ms = ctx.now().ms + std.time.ms_per_day,
    });

    return .{
        .tallies = try tallies.count(),
        .letters = @intCast(basket.word.len),
    };
}
