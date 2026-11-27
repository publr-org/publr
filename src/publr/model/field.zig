//! What a check of a definition finds wrong with its fields.

/// One thing wrong, at a path into the definition: `fields[2].options.to`.
pub const Problem = struct {
    path: []const u8,
    message: []const u8,
};
