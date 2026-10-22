/// Sampler profile
///
/// What the sampler adds to every user.
pub const Fields = struct {
    /// Motto
    motto: ?[]const u8 = null,
};

/// On every user.
pub const location = .{
    .{
        .rules = .{
            .{
                .field = "destination",
                .value = "user",
            },
        },
    },
};
