/// Where a field group goes.
pub const Destination = enum { content, taxonomy, settings, component, user, media };

/// What a plugin's location rule decides for: the account or file being edited.
pub const Target = struct {
    destination: Destination,
    id: []const u8,
};
