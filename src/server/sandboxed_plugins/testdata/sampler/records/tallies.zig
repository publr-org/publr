const publr = @import("publr");

pub const Tally = struct {
    word: []const u8,
    /// Left out of the record until someone sets it.
    checked_at: ?publr.Time = null,
};

pub const record = publr.record.define(Tally, .{
    .name = "sampler.tally",
    .internal = true,
    .indexed = &.{.word},
    .append_only = true,
});
