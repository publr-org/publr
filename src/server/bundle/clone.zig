//! What a bundle made for a clone leaves behind, beyond what any bundle does: a clone is the
//! site, not its people (`clone-and-push.md`), and it may come without its media files, or go
//! back up without the placeholders that stood in for them.
const std = @import("std");
const db = @import("../../lib/db.zig");
const pack = @import("pack.zig");

/// The logs refuse deletes, so their triggers go first; opening the clone makes them again.
/// Every internal record goes: what holds people's data cannot be told from what does not.
const rows = [_][:0]const u8{
    "DROP TRIGGER IF EXISTS activity_kept",
    "DROP TRIGGER IF EXISTS activity_never_removed",
    "DROP TRIGGER IF EXISTS errors_kept",
    "DROP TRIGGER IF EXISTS errors_never_removed",
    "DROP TRIGGER IF EXISTS plugin_log_kept",
    "DROP TRIGGER IF EXISTS plugin_log_never_removed",
    "DELETE FROM activity",
    "DELETE FROM errors",
    "DELETE FROM plugin_log",
    "DELETE FROM secrets",
    "DELETE FROM internal_records",
};
/// Folders and files under the data folder a clone leaves too.
const data_left_out = [_][]const u8{ "environments", "branches", "secret.key" };
pub const media_dir = "media";

/// A bundle made to be worked on elsewhere.
pub const Clone = struct {
    /// The one account it keeps, an administrator there.
    keep_user: ?[]const u8 = null,
    /// False: no media files (the records stay), for a clone that puts placeholders there.
    media: bool = true,
    /// Media storage keys left out because the folder holds only placeholders for them; the
    /// manifest names them, and whoever unpacks it takes the real files from its own source.
    placeholders: []const []const u8 = &.{},
    /// Followed from another thread while it packs.
    progress: ?*pack.Progress = null,
};

/// Whether `path`, under the data folder, stays behind.
pub fn leaves(clone: Clone, path: []const u8) bool {
    std.debug.assert(path.len > 0);
    std.debug.assert(clone.media or clone.placeholders.len == 0);

    for (data_left_out) |item| {
        if (pack.same_path(path, item)) {
            return true;
        }
    }

    if (!clone.media and pack.same_path(path, media_dir)) {
        return true;
    }

    const in_media = path.len > media_dir.len + 1 and std.mem.startsWith(u8, path, media_dir) and
        (path[media_dir.len] == '/' or path[media_dir.len] == std.fs.path.sep);

    if (!in_media) {
        return false;
    }

    const key = path[media_dir.len + 1 ..];

    for (clone.placeholders) |placeholder| {
        if (pack.same_path(key, placeholder)) {
            return true;
        }
    }

    return false;
}

/// A clone's snapshot without its people: only `keep_user`'s account, made an administrator.
pub fn clear(copy: *db.Db, clone: Clone) !void {
    std.debug.assert(rows.len > 0);

    inline for (rows) |statement| {
        try copy.exec(statement);
    }

    const keep = clone.keep_user orelse return;
    var others = try copy.prepare("DELETE FROM users WHERE id != ?1");
    defer others.finalize();

    try others.bind_text(1, keep);
    try others.exec();

    var admin = try copy.prepare(
        "INSERT OR IGNORE INTO user_roles (user_id, role) VALUES (?1, ?2)",
    );
    defer admin.finalize();

    try admin.bind_text(1, keep);
    try admin.bind_text(2, @import("../../model/role.zig").admin);
    try admin.exec();
}

test "a clone leaves its copies, its key, and media it was asked to leave" {
    const placeholders = [_][]const u8{"2026/11/cake-ab12.webp"};
    const without_media: Clone = .{
        .media = false,
    };
    const with_placeholders: Clone = .{
        .placeholders = &placeholders,
    };

    try std.testing.expect(leaves(.{}, "branches"));
    try std.testing.expect(leaves(.{}, "secret.key"));
    try std.testing.expect(!leaves(.{}, "media"));
    try std.testing.expect(leaves(without_media, "media"));
    try std.testing.expect(leaves(with_placeholders, "media/2026/11/cake-ab12.webp"));
    try std.testing.expect(!leaves(with_placeholders, "media/2026/11/other-cd34.webp"));
    try std.testing.expect(!leaves(with_placeholders, "plugins"));
}
