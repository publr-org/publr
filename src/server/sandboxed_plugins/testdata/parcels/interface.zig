//! The contract `parcels` owns, `parcels.carrier`: what a carrier answers when a parcel is
//! quoted (`quote`, how long it takes; required) and, when it can, where one is (`track`).
const publr = @import("publr");

pub const Quote = struct {
    pub const In = struct {
        /// How heavy the parcel is
        grams: u32,
    };
    pub const Out = struct {
        /// How many days it takes to arrive
        days: u32,
    };
};

/// Asked once when a carrier is installed: what it carries, kept as its defaults.
pub const Facts = struct {
    pub const In = struct {};
    pub const Out = struct {
        /// What the carrier carries
        carries: []const u8,
    };
};

pub const Track = struct {
    pub const In = struct {
        /// The carrier's parcel number
        number: []const u8,
    };
    pub const Out = struct {
        /// Where the parcel is now
        at: []const u8,
    };
};

pub const carrier = publr.contract.define(.{
    .name = "parcels.carrier",
    .at_install = .facts,
    .operations = .{
        .facts = Facts,
        .quote = Quote,
    },
    .optional = .{
        .track = Track,
    },
});
