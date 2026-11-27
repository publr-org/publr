//! Where a file of the media library lives, by key: the names a key may take.
const std = @import("std");

pub const key_len_max: u32 = 200;
pub const segments_max: u32 = 4;

/// Up to four `/`-separated segments of `[a-z0-9._-]`, none empty or starting with a dot,
/// so a key never climbs out of its folder or names a hidden file.
pub fn valid_key(key: []const u8) bool {
    std.debug.assert(key_len_max > 0);

    if (key.len == 0 or key.len > key_len_max) {
        return false;
    }

    var segments = std.mem.splitScalar(u8, key, '/');
    var count: u32 = 0;

    while (segments.next()) |segment| {
        count += 1;

        if (count > segments_max or segment.len == 0 or segment[0] == '.') {
            return false;
        }

        for (segment) |char| {
            const allowed = std.ascii.isLower(char) or std.ascii.isDigit(char) or
                char == '.' or char == '-' or char == '_';

            if (!allowed) {
                return false;
            }
        }
    }

    std.debug.assert(count >= 1);

    return true;
}
