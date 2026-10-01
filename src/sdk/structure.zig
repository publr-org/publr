//! What counts as a change to the project's structure: the notices raised when its content
//! types, taxonomies, custom field groups, installed plugins or apps change. What a plugin
//! recording deployments listens for; a record's content is not structure.
const std = @import("std");

/// Each notice's name starts with one of these; the subject names what changed (a type's
/// handle, a plugin's name, an app's name).
pub const prefixes = [_][]const u8{
    "content_type.",
    "taxonomy.",
    "custom_fields.",
    "plugin.",
    "apps.",
};

pub fn is_change(notice_name: []const u8) bool {
    std.debug.assert(notice_name.len > 0);

    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, notice_name, prefix)) {
            return true;
        }
    }

    return false;
}

test "structure is types, taxonomies, field groups, plugins and apps, not content" {
    try std.testing.expect(is_change("content_type.created"));
    try std.testing.expect(is_change("plugin.enabled"));
    try std.testing.expect(is_change("apps.loaded"));
    try std.testing.expect(!is_change("record.published"));
    try std.testing.expect(!is_change("auth.sign_in_succeeded"));
}
