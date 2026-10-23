const publr = @import("publr");

const Place = @import("../kinds/place.zig");

/// Sample visit
///
/// A place the sampler went to, shown on the site by the place's own words.
pub const SampleVisit = struct {
    /// Note
    note: []const u8,
    /// Place
    ///
    /// Where it was.
    place: ?Place.Place = null,
};

pub const record = publr.record.define(SampleVisit, .{
    .name = "sampler.sample_visit",
    .title_field = .note,
    .public = true,
    .fields = .{
        .place = .{
            .kind = "sampler.place",
            .searchable = true,
        },
    },
    .menu = .{
        .parent = &.{"sampler.notes"},
    },
    .data_view = .{
        .columns = &.{ .note, .place },
    },
});
