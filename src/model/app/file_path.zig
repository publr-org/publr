//! Where a file of a project's apps may be: inside the apps folder, under an app's own
//! folder, by a plain relative path.

const std = @import("std");

pub const len_max: u32 = 256;
pub const depth_max: u32 = 8;
/// What one file of an app may hold when an agent writes it as text.
pub const bytes_max: u32 = 1 << 20;

/// `<app>/<path>`: segments of letters, digits, `.`, `-` and `_`, none starting with a dot
/// (no `..`, no hidden files), at least two of them (a file sits in an app's folder), at
/// most eight.
pub fn valid(path: []const u8) bool {
    std.debug.assert(len_max > 0);

    if (path.len == 0 or path.len > len_max) {
        return false;
    }

    var segments = std.mem.splitScalar(u8, path, '/');
    var count: u32 = 0;

    while (segments.next()) |segment| {
        count += 1;

        if (count > depth_max or !valid_segment(segment)) {
            return false;
        }
    }

    return count >= 2;
}

fn valid_segment(segment: []const u8) bool {
    std.debug.assert(segment.len <= len_max);

    if (segment.len == 0 or segment[0] == '.') {
        return false;
    }

    for (segment) |char| {
        const allowed = std.ascii.isAlphanumeric(char) or char == '.' or char == '-' or
            char == '_';

        if (!allowed) {
            return false;
        }
    }

    return true;
}

test "paths stay inside an app's folder" {
    try std.testing.expect(valid("www/pages/index.publr"));
    try std.testing.expect(valid("www/app.zon"));
    try std.testing.expect(!valid("app.zon"));
    try std.testing.expect(!valid("www/../secret"));
    try std.testing.expect(!valid("/etc/passwd"));
    try std.testing.expect(!valid("www/.env"));
    try std.testing.expect(!valid("www//x"));
    try std.testing.expect(!valid("www/a b"));
    try std.testing.expect(!valid("a/b/c/d/e/f/g/h/i"));
}
