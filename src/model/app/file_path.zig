//! Where a file of a project's apps may be: inside the apps folder, under an app's own
//! folder, by a plain relative path.

const std = @import("std");

pub const len_max: u32 = 256;
pub const depth_max: u32 = 8;
/// What one file of an app may hold when an agent writes it as text.
pub const bytes_max: u32 = 1 << 20;

/// `<app>/<path>`: segments of letters, digits, `.`, `-` and `_`, none starting with a dot
/// (no `..`, no hidden files), at least two of them (a file sits in an app's folder), at
/// most eight. A segment may also open with a route parameter, `[slug]` (`[slug].publr`, a
/// page per record), the one place brackets are allowed.
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

    const rest = after_parameter(segment) orelse return false;

    for (rest) |char| {
        const allowed = std.ascii.isAlphanumeric(char) or char == '.' or char == '-' or
            char == '_';

        if (!allowed) {
            return false;
        }
    }

    return true;
}

/// The segment past a leading route parameter (`[slug]`: a name of letters, digits, `-`
/// and `_`), or the whole segment when it opens with none; null for a malformed one.
fn after_parameter(segment: []const u8) ?[]const u8 {
    std.debug.assert(segment.len > 0);

    if (segment[0] != '[') {
        return segment;
    }

    const close = std.mem.indexOfScalar(u8, segment, ']') orelse return null;
    const name = segment[1..close];

    if (name.len == 0) {
        return null;
    }

    for (name) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '-' and char != '_') {
            return null;
        }
    }

    std.debug.assert(close < segment.len);

    return segment[close + 1 ..];
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

test "a page per record takes its route parameter in brackets" {
    try std.testing.expect(valid("www/content/posts/[slug].publr"));
    try std.testing.expect(valid("www/content/[id]/index.publr"));
    try std.testing.expect(!valid("www/content/[].publr"));
    try std.testing.expect(!valid("www/content/[a/b].publr"));
    try std.testing.expect(!valid("www/content/[slug.publr"));
    try std.testing.expect(!valid("www/content/x[slug].publr"));
    try std.testing.expect(!valid("www/content/[..].publr"));
    try std.testing.expect(!valid("www/content/[slug]]"));
}
