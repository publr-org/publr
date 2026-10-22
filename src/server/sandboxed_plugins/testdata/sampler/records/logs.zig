const publr = @import("publr");

/// Sample log
///
/// A line the notes' events leave.
pub const SampleLog = struct {
    /// Line
    line: []const u8,
};

pub const record = publr.record.define(SampleLog, .{
    .name = "sampler.sample_log",
    .title_field = .line,
    .fields = .{
        .line = .{
            .validation = .{
                .required = true,
            },
        },
    },
    .menu = .{
        .parent = &.{"sampler.notes"},
    },
});
