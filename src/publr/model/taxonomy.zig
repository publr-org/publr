/// A plugin's taxonomy on other plugins' types (`.register_taxonomies`), by name or pattern.
pub const Registration = struct {
    /// The taxonomy, whole: `shipping.region`, or core's `tags`.
    taxonomy: []const u8,
    /// One type (`events.event`), every type of a plugin (`products.*`), or every type (`*`).
    to: []const []const u8,
};
