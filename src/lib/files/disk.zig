//! Files on disk under one folder: originals by key, uploads in `.incoming/`, resized copies
//! in `.cache/`. A file is written beside its place and renamed into it, so a reader never
//! sees half of one.

const std = @import("std");
const files = @import("../files.zig");

const Area = files.Area;
const Error = files.Error;
const path_len_max: u32 = files.key_len_max + 64;

pub const Disk = struct {
    io: std.Io,
    root: std.Io.Dir,

    /// Opens the folder, creating it and its areas when missing.
    pub fn open(io: std.Io, path: []const u8) !Disk {
        std.debug.assert(path.len > 0);
        std.debug.assert(path.len < 4096);

        const cwd = std.Io.Dir.cwd();

        try cwd.createDirPath(io, path);

        var root = try cwd.openDir(io, path, .{ .iterate = true });
        errdefer root.close(io);

        try root.createDirPath(io, ".incoming");
        try root.createDirPath(io, ".cache");

        return .{ .io = io, .root = root };
    }

    pub fn close(disk: *Disk) void {
        std.debug.assert(path_len_max > files.key_len_max);

        disk.root.close(disk.io);
        disk.* = undefined;
    }

    pub fn read(
        disk: *Disk,
        allocator: std.mem.Allocator,
        area: Area,
        key: []const u8,
        limit: u32,
    ) Error![]u8 {
        std.debug.assert(files.valid_key(key));
        std.debug.assert(limit > 0);

        var buffer: [path_len_max]u8 = undefined;
        const path = path_of(&buffer, area, key);
        const bounded: std.Io.Limit = .limited(limit + 1);
        const bytes = disk.root.readFileAlloc(disk.io, path, allocator, bounded) catch |err| {
            return switch (err) {
                error.FileNotFound => error.NotFound,
                error.StreamTooLong => error.TooLarge,
                error.OutOfMemory => error.OutOfMemory,
                else => error.Storage,
            };
        };

        if (bytes.len > limit) {
            allocator.free(bytes);
            return error.TooLarge;
        }

        return bytes;
    }

    pub fn read_range(
        disk: *Disk,
        area: Area,
        key: []const u8,
        offset: u64,
        buffer: []u8,
    ) Error![]u8 {
        std.debug.assert(files.valid_key(key));
        std.debug.assert(buffer.len > 0);

        var path_buffer: [path_len_max]u8 = undefined;
        const path = path_of(&path_buffer, area, key);
        var file = disk.root.openFile(disk.io, path, .{}) catch |err| return switch (err) {
            error.FileNotFound => error.NotFound,
            else => error.Storage,
        };
        defer file.close(disk.io);

        const got = file.readPositionalAll(disk.io, buffer, offset) catch return error.Storage;

        return buffer[0..got];
    }

    pub fn write(disk: *Disk, area: Area, key: []const u8, bytes: []const u8) Error!void {
        std.debug.assert(files.valid_key(key));
        std.debug.assert(bytes.len <= files.bytes_max);

        var buffer: [path_len_max]u8 = undefined;
        var temporary_buffer: [path_len_max + 8]u8 = undefined;
        const path = path_of(&buffer, area, key);
        const temporary = std.fmt.bufPrint(&temporary_buffer, "{s}.writing", .{path}) catch
            unreachable;

        disk.make_parent(path) catch return error.Storage;
        disk.root.writeFile(disk.io, .{ .sub_path = temporary, .data = bytes }) catch
            return error.Storage;
        disk.root.rename(temporary, disk.root, path, disk.io) catch return error.Storage;
    }

    pub fn append(
        disk: *Disk,
        area: Area,
        key: []const u8,
        offset: u64,
        bytes: []const u8,
    ) Error!u64 {
        std.debug.assert(files.valid_key(key));
        std.debug.assert(offset + bytes.len <= files.bytes_max);

        var buffer: [path_len_max]u8 = undefined;
        const path = path_of(&buffer, area, key);

        disk.make_parent(path) catch return error.Storage;

        var file = open_piece(disk, path, offset) catch |err| return switch (err) {
            error.FileNotFound => error.OutOfOrder,
            else => error.Storage,
        };
        defer file.close(disk.io);

        const size = (file.stat(disk.io) catch return error.Storage).size;

        if (size != offset) {
            return error.OutOfOrder;
        }

        file.writePositionalAll(disk.io, bytes, size) catch return error.Storage;

        return size + bytes.len;
    }

    fn open_piece(disk: *Disk, path: []const u8, offset: u64) !std.Io.File {
        std.debug.assert(path.len > 0);
        std.debug.assert(offset <= files.bytes_max);

        if (offset == 0) {
            return disk.root.createFile(disk.io, path, .{ .truncate = true });
        }

        return disk.root.openFile(disk.io, path, .{ .mode = .read_write });
    }

    pub fn remove(disk: *Disk, area: Area, key: []const u8) void {
        std.debug.assert(files.valid_key(key));
        std.debug.assert(path_len_max > key.len);

        var buffer: [path_len_max]u8 = undefined;
        const path = path_of(&buffer, area, key);

        disk.root.deleteFile(disk.io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => std.log.warn("media: could not remove {s}: {t}", .{ path, err }),
        };
    }

    /// Every cached copy of `key` is named after its stem, beside where the key's folder is.
    pub fn clear_copies(disk: *Disk, key: []const u8) void {
        std.debug.assert(files.valid_key(key));
        std.debug.assert(path_len_max > key.len);

        var buffer: [path_len_max]u8 = undefined;
        const slash = std.mem.lastIndexOfScalar(u8, key, '/');
        const folder = if (slash) |index| key[0..index] else "";
        const path = std.fmt.bufPrint(&buffer, ".cache/{s}", .{folder}) catch unreachable;
        var dir = disk.root.openDir(disk.io, path, .{ .iterate = true }) catch return;
        defer dir.close(disk.io);

        const stem = files.stem_of(key);
        var iterator = dir.iterate();
        var seen: u32 = 0;

        while (iterator.next(disk.io) catch null) |entry| : (seen += 1) {
            if (seen == copies_scanned_max) {
                break;
            }

            const rest = std.mem.cutPrefix(u8, entry.name, stem) orelse continue;

            if (entry.kind == .file and rest.len > 0 and (rest[0] == '_' or rest[0] == '.')) {
                dir.deleteFile(disk.io, entry.name) catch |err| {
                    std.log.warn("media: could not remove a copy of {s}: {t}", .{ key, err });
                };
            }
        }
    }

    fn make_parent(disk: *Disk, path: []const u8) !void {
        std.debug.assert(path.len > 0);
        std.debug.assert(path[0] != '/');

        const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;

        try disk.root.createDirPath(disk.io, path[0..slash]);
    }
};

/// How many entries of one cache folder a clear looks at: a month of uploads' copies.
const copies_scanned_max: u32 = 100_000;

fn path_of(buffer: *[path_len_max]u8, area: Area, key: []const u8) []const u8 {
    std.debug.assert(key.len <= files.key_len_max);
    std.debug.assert(files.valid_key(key));

    const prefix = switch (area) {
        .files => "",
        .incoming => ".incoming/",
        .cache => ".cache/",
    };

    return std.fmt.bufPrint(buffer, "{s}{s}", .{ prefix, key }) catch unreachable;
}

test "disk: write, read, pieces in order, copies cleared, nothing outside the folder" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    const root = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const media_path = try std.fs.path.join(std.testing.allocator, &.{ root, "media" });
    defer std.testing.allocator.free(media_path);

    var disk = try Disk.open(io, media_path);
    defer disk.close();

    const stored: files.Files = .{ .disk = &disk };

    try stored.write(.files, "2026/10/cat-abc123.jpg", "meow");

    const read = try stored.read(std.testing.allocator, .files, "2026/10/cat-abc123.jpg", 64);
    defer std.testing.allocator.free(read);

    try std.testing.expectEqualStrings("meow", read);
    try std.testing.expectError(
        error.TooLarge,
        stored.read(std.testing.allocator, .files, "2026/10/cat-abc123.jpg", 2),
    );
    try std.testing.expectError(
        error.NotFound,
        stored.read(std.testing.allocator, .files, "2026/10/dog.jpg", 64),
    );
    try std.testing.expectError(error.InvalidKey, stored.write(.files, "../escape", "x"));
    try std.testing.expectEqual(@as(u64, 3), try stored.append(.incoming, "up1", 0, "abc"));
    try std.testing.expectEqual(@as(u64, 5), try stored.append(.incoming, "up1", 3, "de"));
    try std.testing.expectError(error.OutOfOrder, stored.append(.incoming, "up1", 9, "x"));
    try std.testing.expectError(error.OutOfOrder, stored.append(.incoming, "up2", 4, "x"));

    try stored.write(.cache, "2026/10/cat-abc123_w200.jpg", "small");
    try stored.write(.cache, "2026/10/cat-abc1234_w200.jpg", "other");
    stored.clear_copies("2026/10/cat-abc123.jpg");

    try std.testing.expectError(
        error.NotFound,
        stored.read(std.testing.allocator, .cache, "2026/10/cat-abc123_w200.jpg", 64),
    );

    const kept = try stored.read(std.testing.allocator, .cache, "2026/10/cat-abc1234_w200.jpg", 64);
    defer std.testing.allocator.free(kept);

    try std.testing.expectEqualStrings("other", kept);
    stored.remove(.files, "2026/10/cat-abc123.jpg");
    stored.remove(.files, "2026/10/cat-abc123.jpg");
    try std.testing.expectError(
        error.NotFound,
        stored.read(std.testing.allocator, .files, "2026/10/cat-abc123.jpg", 64),
    );
}
