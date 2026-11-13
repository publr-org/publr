//! Media a clone came without (`publr clone --media none`): every media record stays, and a
//! placeholder of the same width, height and type stands in for its file, so pages lay out
//! as they will live. `.publr/placeholders` lists them with their sizes; `push` leaves out
//! each one still there unchanged, so a live file is never replaced by a placeholder.
const std = @import("std");
const db = @import("../../lib/db.zig");
const files = @import("../../lib/files.zig");
const image = @import("../../lib/image.zig");
const encode = @import("../../lib/image/encode.zig").encode;

pub const list_path = ".publr/placeholders";
const database_path = "data/publr.db";
const media_dir = "data/media";
/// The longest side a placeholder is drawn at; the record keeps the real size.
const side_max: u32 = 1600;
const side_default: u32 = 800;
const page_rows: u32 = 500;
const list_bytes_max: u32 = 64 << 20;
const grey: u8 = 228;

const Row = struct {
    record: []const u8,
    storage_key: []const u8,
    mime_type: []const u8,
    width: ?i64,
    height: ?i64,
};

pub const Written = struct {
    files: u32,
    bytes: u64,
};

/// A placeholder for every media record of the clone in `folder`, and their list.
pub fn write_all(io: std.Io, arena: std.mem.Allocator, folder: []const u8) !Written {
    std.debug.assert(folder.len > 0);

    var runtime = try db.Runtime.init(.{});
    defer runtime.deinit();

    var connection = try db.open(&runtime, try std.fs.path.joinZ(arena, &.{
        folder,
        database_path,
    }));
    defer connection.close();

    var list: std.Io.Writer.Allocating = .init(arena);
    var written: Written = .{
        .files = 0,
        .bytes = 0,
    };
    var after: []const u8 = "";

    while (true) {
        var page_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer page_arena.deinit();

        const rows = try page_of(&connection, page_arena.allocator(), after);

        for (rows) |row| {
            const bytes = try write_one(io, page_arena.allocator(), folder, row) orelse continue;

            try list.writer.print("{s}\t{d}\n", .{ row.storage_key, bytes });
            written.files += 1;
            written.bytes += bytes;
        }

        if (rows.len < page_rows) {
            break;
        }

        after = try arena.dupe(u8, rows[rows.len - 1].record);
    }

    const path = try std.fs.path.join(arena, &.{ folder, list_path });

    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = list.written(),
    });

    return written;
}

fn page_of(connection: *db.Db, arena: std.mem.Allocator, after: []const u8) ![]const Row {
    std.debug.assert(page_rows > 0);

    var select = try connection.prepare(
        "SELECT record, storage_key, mime_type, width, height FROM media " ++
            "WHERE record > ?1 ORDER BY record LIMIT ?2",
    );
    defer select.finalize();

    try select.bind_text(1, after);
    try select.bind_int(2, page_rows);

    var found: std.ArrayList(Row) = .empty;

    while (try select.step()) {
        try found.append(arena, try select.read(Row, arena));
    }

    return found.items;
}

/// The placeholder's size in bytes, or null for a key no file may have.
fn write_one(io: std.Io, arena: std.mem.Allocator, folder: []const u8, row: Row) !?u64 {
    std.debug.assert(folder.len > 0);

    if (!files.valid_key(row.storage_key)) {
        return null;
    }

    const bytes = try drawn(arena, row);
    const path = try std.fs.path.join(arena, &.{ folder, media_dir, row.storage_key });

    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = bytes,
    });

    return bytes.len;
}

/// A plain grey picture in the record's type at its size (its longest side at most
/// `side_max`); an SVG of its size; for any other file, nothing.
pub fn drawn(arena: std.mem.Allocator, row: Row) ![]const u8 {
    std.debug.assert(side_max > 0);

    const size = fitted(row.width, row.height);

    if (std.mem.eql(u8, row.mime_type, "image/svg+xml")) {
        return std.fmt.allocPrint(arena, "<svg xmlns=\"http://www.w3.org/2000/svg\" " ++
            "width=\"{d}\" height=\"{d}\"><rect width=\"100%\" height=\"100%\" " ++
            "fill=\"#e4e4e7\"/></svg>\n", .{ size.width, size.height });
    }

    const format = format_of(row.mime_type) orelse return "";
    const pixels = try arena.alloc(u8, @as(usize, size.width) * size.height * 3);

    @memset(pixels, grey);

    return encode(arena, .{
        .bytes = pixels,
        .width = size.width,
        .height = size.height,
        .channels = 3,
    }, format, 60) catch error.PlaceholderNotDrawn;
}

const Fitted = struct {
    width: u32,
    height: u32,
};

fn fitted(width: ?i64, height: ?i64) Fitted {
    const given_width: u64 = @intCast(@max(width orelse 0, 0));
    const given_height: u64 = @intCast(@max(height orelse 0, 0));

    if (given_width == 0 or given_height == 0) {
        return .{
            .width = side_default,
            .height = side_default * 3 / 4,
        };
    }

    const longest = @max(given_width, given_height);
    const over = longest > side_max;
    const scaled_width = if (over) given_width * side_max / longest else given_width;
    const scaled_height = if (over) given_height * side_max / longest else given_height;

    std.debug.assert(@max(scaled_width, scaled_height) <= @max(side_max, longest));

    return .{
        .width = @intCast(@max(scaled_width, 1)),
        .height = @intCast(@max(scaled_height, 1)),
    };
}

fn format_of(mime_type: []const u8) ?image.Format {
    std.debug.assert(mime_type.len <= 255);

    if (std.mem.eql(u8, mime_type, "image/jpeg")) {
        return .jpeg;
    }

    if (std.mem.eql(u8, mime_type, "image/png") or std.mem.eql(u8, mime_type, "image/gif")) {
        return .png;
    }

    if (std.mem.eql(u8, mime_type, "image/webp") and image.webp_written) {
        return .webp;
    }

    return null;
}

/// The storage keys under `folder` whose files are still the placeholders `write_all` left:
/// one replaced since (a real file fetched, an image edited) is the folder's own again.
pub fn still_there(io: std.Io, arena: std.mem.Allocator, folder: []const u8) ![]const []const u8 {
    std.debug.assert(folder.len > 0);

    const cwd = std.Io.Dir.cwd();
    const path = try std.fs.path.join(arena, &.{ folder, list_path });
    const text = cwd.readFileAlloc(io, path, arena, .limited(list_bytes_max)) catch |err| {
        return switch (err) {
            error.FileNotFound => &.{},
            else => err,
        };
    };
    var kept: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');

    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const key = line[0..tab];
        const bytes = std.fmt.parseInt(u64, line[tab + 1 ..], 10) catch continue;
        const file = try std.fs.path.join(arena, &.{ folder, media_dir, key });
        const stat = cwd.statFile(io, file, .{}) catch continue;

        if (stat.size == bytes and files.valid_key(key)) {
            try kept.append(arena, key);
        }
    }

    return kept.items;
}

test "a placeholder keeps the picture's shape and type, at a bounded size" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const wide = fitted(4000, 2000);

    try std.testing.expectEqual(@as(u32, 1600), wide.width);
    try std.testing.expectEqual(@as(u32, 800), wide.height);
    try std.testing.expectEqual(@as(u32, 800), fitted(null, 10).width);
    try std.testing.expectEqual(@as(u32, 300), fitted(300, 200).width);

    const png = try drawn(arena, .{
        .record = "a",
        .storage_key = "2026/11/a.png",
        .mime_type = "image/png",
        .width = 40,
        .height = 20,
    });
    const svg = try drawn(arena, .{
        .record = "b",
        .storage_key = "2026/11/b.svg",
        .mime_type = "image/svg+xml",
        .width = 40,
        .height = 20,
    });

    try std.testing.expect(std.mem.startsWith(u8, png, "\x89PNG"));
    try std.testing.expectEqual(@as(u32, 40), image.size_of(png).?.width);
    try std.testing.expect(std.mem.indexOf(u8, svg, "width=\"40\"") != null);
    try std.testing.expect(format_of("application/pdf") == null);
}

test "a placeholder replaced since is the folder's own again" {
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const io = std.testing.io;
    const root = try scratch.dir.realPathFileAlloc(io, ".", arena);

    try scratch.dir.createDirPath(io, "data/media/2026/11");
    try scratch.dir.createDirPath(io, ".publr");
    try scratch.dir.writeFile(io, .{
        .sub_path = "data/media/2026/11/kept.png",
        .data = "1234",
    });
    try scratch.dir.writeFile(io, .{
        .sub_path = "data/media/2026/11/fetched.png",
        .data = "the real one",
    });
    try scratch.dir.writeFile(io, .{
        .sub_path = list_path,
        .data = "2026/11/kept.png\t4\n2026/11/fetched.png\t4\n",
    });

    const kept = try still_there(io, arena, root);

    try std.testing.expectEqual(@as(usize, 1), kept.len);
    try std.testing.expectEqualStrings("2026/11/kept.png", kept[0]);
}
