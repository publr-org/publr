//! Files kept by key beside the database: the media library's originals, the pieces of an
//! upload on its way in, and resized copies. Natively they are a folder on disk; in the
//! browser the service worker keeps them in OPFS and the module never touches them itself
//! (`files/deferred.zig`): it asks for a file it lacks and is run again with it, and what it
//! writes goes out with the response.

const std = @import("std");
pub const kept_elsewhere = @import("files/deferred.zig");
pub const Deferred = kept_elsewhere.Deferred;
const disk = @import("files/disk.zig");
pub const dropped = @import("files/dropped.zig");

pub const Disk = disk.Disk;

/// The largest file kept: an upload, or an original read back.
pub const bytes_max: u32 = 32 << 20;
pub const key_len_max: u32 = 200;
pub const segments_max: u32 = 4;

/// Where a file lives: an original, an upload arriving in pieces, or a resized copy that
/// can be thrown away and made again.
pub const Area = enum(u8) { files, incoming, cache };

pub const Error = error{
    /// No file under that key.
    NotFound,
    /// The browser's worker has not handed the file over yet; the request runs again with it.
    Needed,
    /// A piece that does not start where the upload ends.
    OutOfOrder,
    TooLarge,
    InvalidKey,
    /// The disk refused: full, gone, no permission.
    Storage,
    OutOfMemory,
};

pub const Files = union(enum) {
    disk: *Disk,
    deferred: *Deferred,

    /// The whole file, from `allocator`, up to `limit` bytes.
    pub fn read(
        files: Files,
        allocator: std.mem.Allocator,
        area: Area,
        key: []const u8,
        limit: u32,
    ) Error![]u8 {
        std.debug.assert(limit > 0 and limit <= bytes_max);

        if (!valid_key(key)) {
            return error.InvalidKey;
        }

        return switch (files) {
            .disk => |stored| stored.read(allocator, area, key, limit),
            .deferred => |deferred| deferred.read(allocator, area, key, limit),
        };
    }

    /// `len` bytes of the file from `offset`, into the caller's `buffer`.
    pub fn read_range(
        files: Files,
        area: Area,
        key: []const u8,
        offset: u64,
        buffer: []u8,
    ) Error![]u8 {
        std.debug.assert(buffer.len > 0 and buffer.len <= bytes_max);

        if (!valid_key(key)) {
            return error.InvalidKey;
        }

        return switch (files) {
            .disk => |stored| stored.read_range(area, key, offset, buffer),
            .deferred => |deferred| deferred.read_range(area, key, offset, buffer),
        };
    }

    /// Creates or replaces the file.
    pub fn write(files: Files, area: Area, key: []const u8, bytes: []const u8) Error!void {
        std.debug.assert(bytes.len <= bytes_max);

        if (!valid_key(key)) {
            return error.InvalidKey;
        }

        return switch (files) {
            .disk => |stored| stored.write(area, key, bytes),
            .deferred => |deferred| deferred.write(area, key, bytes),
        };
    }

    /// Adds a piece at `offset`: 0 starts the file afresh, any other must be where it ends.
    /// Answers the file's size after it.
    pub fn append(
        files: Files,
        area: Area,
        key: []const u8,
        offset: u64,
        bytes: []const u8,
    ) Error!u64 {
        std.debug.assert(bytes.len <= bytes_max);

        if (!valid_key(key)) {
            return error.InvalidKey;
        }

        if (offset + bytes.len > bytes_max) {
            return error.TooLarge;
        }

        const size = switch (files) {
            .disk => |stored| try stored.append(area, key, offset, bytes),
            .deferred => |deferred| try deferred.append(area, key, offset, bytes),
        };

        std.debug.assert(size == offset + bytes.len);

        return size;
    }

    /// Removes the file; one already gone is fine.
    pub fn remove(files: Files, area: Area, key: []const u8) void {
        std.debug.assert(key.len > 0);

        if (!valid_key(key)) {
            return;
        }

        switch (files) {
            .disk => |stored| stored.remove(area, key),
            .deferred => |deferred| deferred.remove(area, key),
        }
    }

    /// Removes every resized copy made from `key`: the cache's files named after its stem.
    pub fn clear_copies(files: Files, key: []const u8) void {
        std.debug.assert(key.len > 0);

        if (!valid_key(key)) {
            return;
        }

        switch (files) {
            .disk => |stored| stored.clear_copies(key),
            .deferred => {},
        }
    }

    /// Whether resized copies are kept: on disk, never in the browser.
    pub fn caches(files: Files) bool {
        const kept = files == .disk;

        std.debug.assert(kept or files == .deferred);

        return kept;
    }
};

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

/// The part of a key's last segment before its extension: `2026/10/cat-a1b2c3.jpg` is
/// `cat-a1b2c3`.
pub fn stem_of(key: []const u8) []const u8 {
    std.debug.assert(key.len > 0);

    const slash = std.mem.lastIndexOfScalar(u8, key, '/');
    const name = if (slash) |index| key[index + 1 ..] else key;
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse name.len;

    std.debug.assert(dot <= name.len);

    return name[0..dot];
}

test "valid_key: dated names in, anything that escapes out" {
    try std.testing.expect(valid_key("2026/10/cat-a1b2c3.jpg"));
    try std.testing.expect(valid_key("upload_1"));
    try std.testing.expect(!valid_key(""));
    try std.testing.expect(!valid_key("../secret"));
    try std.testing.expect(!valid_key("2026/.hidden"));
    try std.testing.expect(!valid_key("2026//cat.jpg"));
    try std.testing.expect(!valid_key("/cat.jpg"));
    try std.testing.expect(!valid_key("Cat.jpg"));
    try std.testing.expect(!valid_key("a/b/c/d/e"));
    try std.testing.expect(!valid_key("cat\x00.jpg"));
}

test "stem_of: the last segment without its extension" {
    try std.testing.expectEqualStrings("cat-a1b2c3", stem_of("2026/10/cat-a1b2c3.jpg"));
    try std.testing.expectEqualStrings("notes", stem_of("notes"));
    try std.testing.expectEqualStrings("archive.tar", stem_of("archive.tar.gz"));
}

test {
    std.testing.refAllDecls(@This());
}
