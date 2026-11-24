const publr = @import("publr");
const std = @import("std");

/// Weight
///
/// What a thing weighs, in grams.
pub const Weight = struct {
    /// Grams
    grams: i64,
};

/// A weight is never below nothing.
fn validate(weight: Weight, problems: *publr.Problems(Weight)) void {
    std.debug.assert(weight.grams > std.math.minInt(i64));

    if (weight.grams < 0) {
        problems.add(.grams, "Not below 0.");
    }
}

/// Only the sampler's code puts it on a type: on greeter's salutations, in its parcel group.
pub const kind = publr.field.kind(Weight, .{
    .name = "weight",
    .icon = "package",
    .validate = validate,
    .code_only = true,
});
