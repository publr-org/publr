//! Files put into the media folder by hand, beside the library's own: found by walking the
//! folder (never its hidden areas), read by their path, and taken into the library where
//! they lie or moved under a key.

const std = @import("std");
const files = @import("../files.zig");
const Disk = @import("disk.zig").Disk;

const Error = files.Error;

/// How many files one walk reports; a folder holding more is walked again after the first
/// are taken in.
pub const found_max: u32 = 10_000;
/// How deep a walk goes below the folder.
pub const depth_max: u32 = 8;
pub const path_len_max: u32 = 512;

pub const Found = struct {
    /// Relative to the folder, `/`-separated.
    path: []const u8,
    size: u64,
};

pub const Walked = struct {
    found: []const Found,
    /// More files lie in the folder than one walk reports.
    more: bool,
};

/// Every file under the folder outside its hidden areas, with its size.
pub fn walk(disk: *Disk, arena: std.mem.Allocator) Error!Walked {
    std.debug.assert(found_max > 0);
    std.debug.assert(depth_max > 0);

    var walker = disk.root.walkSelectively(arena) catch return error.OutOfMemory;
    defer walker.deinit();

    var found: std.ArrayList(Found) = .empty;

    while (walker.next(disk.io) catch return error.Storage) |entry| {
        if (entry.basename[0] == '.' or entry.path.len > path_len_max) {
            continue;
        }

        if (entry.kind == .directory) {
            if (entry.depth() < depth_max) {
                walker.enter(disk.io, entry) catch return error.Storage;
            }

            continue;
        }

        if (entry.kind != .file or std.mem.endsWith(u8, entry.basename, ".writing")) {
            continue;
        }

        if (found.items.len == found_max) {
            return .{ .found = found.items, .more = true };
        }

        const stat = entry.dir.statFile(disk.io, entry.basename, .{}) catch continue;

        try found.append(arena, .{
            .path = try slashed(arena, entry.path),
            .size = stat.size,
        });
    }

    std.debug.assert(found.items.len <= found_max);

    return .{ .found = found.items, .more = false };
}

fn slashed(arena: std.mem.Allocator, path: []const u8) Error![]const u8 {
    std.debug.assert(path.len > 0);

    const copy = try arena.dupe(u8, path);

    if (std.fs.path.sep != '/') {
        std.mem.replaceScalar(u8, copy, std.fs.path.sep, '/');
    }

    return copy;
}

pub fn read(
    disk: *Disk,
    allocator: std.mem.Allocator,
    path: []const u8,
    limit: u32,
) Error![]u8 {
    std.debug.assert(path.len > 0 and path.len <= path_len_max);
    std.debug.assert(limit > 0);

    const bytes = disk.root.readFileAlloc(disk.io, path, allocator, .limited(limit + 1)) catch |err|
        return switch (err) {
            error.FileNotFound => error.NotFound,
            error.StreamTooLong => error.TooLarge,
            error.OutOfMemory => error.OutOfMemory,
            else => error.Storage,
        };

    if (bytes.len > limit) {
        allocator.free(bytes);
        return error.TooLarge;
    }

    return bytes;
}

/// Moves the file at `path` to `key`, unless it is there already.
pub fn adopt(disk: *Disk, path: []const u8, key: []const u8) Error!void {
    std.debug.assert(path.len > 0 and path.len <= path_len_max);
    std.debug.assert(files.valid_key(key));

    if (std.mem.eql(u8, path, key)) {
        return;
    }

    if (std.mem.lastIndexOfScalar(u8, key, '/')) |slash| {
        disk.root.createDirPath(disk.io, key[0..slash]) catch return error.Storage;
    }

    disk.root.rename(path, disk.root, key, disk.io) catch return error.Storage;
    prune(disk, path);
}

/// Removes the directories a moved file leaves empty, innermost first.
fn prune(disk: *Disk, path: []const u8) void {
    std.debug.assert(path.len > 0);
    std.debug.assert(path[0] != '/');

    var rest = path;

    while (std.mem.lastIndexOfScalar(u8, rest, '/')) |slash| {
        rest = rest[0..slash];
        disk.root.deleteDir(disk.io, rest) catch return;
    }
}

/// Forgets a file put in by hand once the library keeps its bytes elsewhere.
pub fn remove(disk: *Disk, path: []const u8) void {
    std.debug.assert(path.len > 0 and path.len <= path_len_max);
    std.debug.assert(path[0] != '/');

    disk.root.deleteFile(disk.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => std.log.warn("media: could not remove {s}: {t}", .{ path, err }),
    };
    prune(disk, path);
}

/// Whether a file of the library is still in the folder.
pub fn exists(disk: *Disk, key: []const u8) bool {
    std.debug.assert(key.len > 0);
    std.debug.assert(files.valid_key(key));

    _ = disk.root.statFile(disk.io, key, .{}) catch return false;

    return true;
}

test "dropped: walked without hidden areas, read, moved under a key, found gone" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    const root = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const media_path = try std.fs.path.join(std.testing.allocator, &.{ root, "media" });
    defer std.testing.allocator.free(media_path);

    var disk = try Disk.open(io, media_path);
    defer disk.close();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try disk.root.createDirPath(io, "Photos/Trips");
    try disk.root.writeFile(io, .{ .sub_path = "Photos/Trips/Beach Day.JPG", .data = "sand" });
    try disk.root.writeFile(io, .{ .sub_path = ".DS_Store", .data = "x" });
    try disk.root.writeFile(io, .{ .sub_path = ".cache/copy.jpg", .data = "x" });

    const walked = try walk(&disk, arena);

    try std.testing.expectEqual(@as(usize, 1), walked.found.len);
    try std.testing.expectEqualStrings("Photos/Trips/Beach Day.JPG", walked.found[0].path);
    try std.testing.expectEqual(@as(u64, 4), walked.found[0].size);
    try std.testing.expect(!walked.more);

    const bytes = try read(&disk, arena, walked.found[0].path, 64);

    try std.testing.expectEqualStrings("sand", bytes);
    try std.testing.expectError(error.TooLarge, read(&disk, arena, walked.found[0].path, 2));
    try adopt(&disk, walked.found[0].path, "2026/10/beach-day-a1b2c3.jpg");
    try std.testing.expect(exists(&disk, "2026/10/beach-day-a1b2c3.jpg"));
    try std.testing.expect(!exists(&disk, "2026/10/gone.jpg"));
    try std.testing.expectError(error.FileNotFound, disk.root.statFile(io, "Photos", .{}));
    try std.testing.expectError(
        error.NotFound,
        read(&disk, arena, "Photos/Trips/Beach Day.JPG", 64),
    );
}
