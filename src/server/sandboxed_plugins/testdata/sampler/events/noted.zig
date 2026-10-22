const publr = @import("publr");

/// Every word noted.
pub const Payload = struct {
    /// The note, in capitals
    note: []const u8,
};

/// A note was kept.
pub const event = publr.event.define(.{
    .name = "noted",
    .payload = Payload,
});
