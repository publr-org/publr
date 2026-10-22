const publr = @import("publr");

/// Sample note
///
/// A note the sampler keeps.
pub const SampleNote = struct {
    /// Note
    note: []const u8,
};

pub const record = publr.record.define(SampleNote, .{
    .name = "sampler.sample_note",
    .title_field = .note,
    .fields = .{
        .note = .{
            .validation = .{
                .required = true,
            },
        },
    },
    .menu = .{
        .parent = &.{"sampler.notes"},
    },
    .data_view = .{
        .columns = &.{.note},
    },
});

/// The notes, read by type.
pub const typed = publr.records.of(SampleNote, "sampler.sample_note");
