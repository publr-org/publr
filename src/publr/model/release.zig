//! Publr's releases as an update reads them, and the backups an update leaves.

pub const Kind = enum { patch, minor, major };

pub const Release = struct {
    version: []const u8,
    kind: Kind,
    /// The release notes, cut at `notes_bytes_max`.
    notes: []const u8,
    published_at: []const u8,
    url: []const u8,
};

/// A backup an update made of the whole site before it swapped the binary.
pub const UpdateBackup = struct {
    name: []const u8,
    /// The release that last opened the site before; empty when none recorded one.
    from: []const u8,
    to: []const u8,
    at_ms: i64,
};
