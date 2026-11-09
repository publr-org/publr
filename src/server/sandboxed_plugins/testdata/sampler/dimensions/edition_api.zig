//! The sampler's editions, as other plugins' fields and reads say them.

const publr = @import("publr");

/// Whether the field keeps another value for the print edition.
pub const Printed = enum {
    /// Same in print
    /// One value for the web and print.
    same,
    /// Its own in print
    /// A value for print; one left empty prints the web's.
    own,
};

fn holds(printed: Printed) publr.dimension.Holds {
    return switch (printed) {
        .same => .one,
        .own => .fallback,
    };
}

/// Per edition
pub const field = publr.dimension.field_option(.{
    .name = "printed",
    .takes = Printed,
    .holds = holds,
    .options = publr.views.all.SamplerPrinted,
});

/// Edition
pub const read = publr.dimension.read_option(.{
    .name = "edition",
});
