const publr = @import("publr");

pub const Tally = struct {
    word: []const u8,
};

pub const record = publr.record.define(Tally, .{
    .name = "sampler.tally",
    .internal = true,
    .indexed = &.{.word},
    .append_only = true,
});

/// The tallies, read by kind.
pub const typed = publr.internal.of(Tally, "tally");
