const Weight = @import("../kinds/weight.zig");

/// Sampler parcel
///
/// What the sampler keeps on each of greeter's salutations, published with it.
pub const Fields = struct {
    /// Weight
    ///
    /// What the salutation weighs when it is sent.
    weight: ?Weight.Weight = null,
};

/// On greeter's salutations: another plugin's type.
pub const location = .{
    .{
        .rules = .{
            .{
                .field = "destination",
                .value = "content",
            },
            .{
                .field = "type",
                .value = "greeter.salutation",
            },
        },
    },
};
