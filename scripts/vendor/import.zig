const std = @import("std");

const files_max: u32 = 20_000;
const args_max: u32 = 64;
const archive_bytes_max: u32 = 64 << 20;
const window_len = std.compress.flate.max_window_len;

const Arguments = struct {
    archive_path: []const u8,
    target_root: []const u8,
    name: []const u8,
    version: []const u8,
    upstream: []const u8,
    keep: []const []const u8,
};

pub fn run(init: std.process.Init, raw_args: []const []const u8) !u8 {
    const args = try parse_args(init, raw_args);
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    std.debug.assert(args.keep.len > 0);
    std.debug.assert(std.fs.path.isAbsolute(args.archive_path));
    std.debug.assert(std.fs.path.isAbsolute(args.target_root));

    const sha256_hex = try archive_sha256_hex(io, init.gpa, args.archive_path);
    const staging_root = try std.fmt.allocPrint(
        init.arena.allocator(),
        "{s}.staging",
        .{args.target_root},
    );

    try cwd.deleteTree(io, staging_root);
    defer cwd.deleteTree(io, staging_root) catch |err| {
        std.debug.print("staging dir left behind ({t}): {s}\n", .{ err, staging_root });
    };

    const staging = try cwd.createDirPathOpen(io, staging_root, .{
        .open_options = .{
            .iterate = true,
        },
    });

    try extract_archive(io, init.gpa, args.archive_path, staging);

    const source = try open_single_top_dir(io, staging);

    try cwd.deleteTree(io, args.target_root);

    const target = try cwd.createDirPathOpen(io, args.target_root, .{});

    var files_copied: u32 = 0;

    for (args.keep) |keep| {
        files_copied += try copy_path(io, init.gpa, source, target, keep);
        std.debug.assert(files_copied <= files_max);
    }

    std.debug.assert(files_copied > 0);

    try write_version(io, target, args, &sha256_hex, files_copied);

    return 0;
}

fn parse_args(init: std.process.Init, list: []const []const u8) !Arguments {
    std.debug.assert(list.len < 1 << 16);
    std.debug.assert(args_max > 6);

    return parse_args_with(init.arena.allocator(), list);
}

fn parse_args_with(arena: std.mem.Allocator, list: []const []const u8) !Arguments {
    if (list.len > args_max) {
        return error.TooManyArguments;
    }

    if (list.len < 6) {
        return error.MissingArguments;
    }

    std.debug.assert(list.len <= args_max);

    const keep = try arena.dupe([]const u8, list[5..]);

    std.debug.assert(keep.len == list.len - 5);

    return .{
        .archive_path = list[0],
        .target_root = list[1],
        .name = list[2],
        .version = list[3],
        .upstream = list[4],
        .keep = keep,
    };
}

fn archive_sha256_hex(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![64]u8 {
    std.debug.assert(path.len > 0);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(archive_bytes_max));
    defer gpa.free(bytes);

    std.debug.assert(bytes.len > 0);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});

    return std.fmt.bytesToHex(digest, .lower);
}

fn extract_archive(io: std.Io, gpa: std.mem.Allocator, path: []const u8, dest: std.Io.Dir) !void {
    std.debug.assert(path.len > 4);
    std.debug.assert(std.fs.path.isAbsolute(path));

    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var file_buffer: [64 << 10]u8 = undefined;
    var file_reader = file.reader(io, &file_buffer);

    if (std.mem.endsWith(u8, path, ".zip")) {
        try std.zip.extract(dest, &file_reader, .{});
        return;
    }

    if (!std.mem.endsWith(u8, path, ".tar.gz")) {
        return error.UnsupportedArchive;
    }

    const window = try gpa.alloc(u8, window_len);
    defer gpa.free(window);

    var decompress = std.compress.flate.Decompress.init(&file_reader.interface, .gzip, window);

    try std.tar.extract(io, dest, &decompress.reader, .{
        .mode_mode = .ignore,
    });
}

fn open_single_top_dir(io: std.Io, staging: std.Io.Dir) !std.Io.Dir {
    var iterator = staging.iterate();
    var top_name: ?[]const u8 = null;
    var name_buffer: [256]u8 = undefined;
    var entries: u32 = 0;

    while (try iterator.next(io)) |entry| : (entries += 1) {
        if (entries == 1) {
            return error.ArchiveHasNoSingleTopDir;
        }
        if (entry.kind != .directory) {
            return error.ArchiveHasNoSingleTopDir;
        }
        if (entry.name.len > name_buffer.len) {
            return error.NameTooLong;
        }

        @memcpy(name_buffer[0..entry.name.len], entry.name);
        top_name = name_buffer[0..entry.name.len];
    }

    const name = top_name orelse return error.ArchiveEmpty;

    std.debug.assert(entries == 1);
    std.debug.assert(name.len > 0);

    return staging.openDir(io, name, .{
        .iterate = true,
    });
}

fn copy_path(
    io: std.Io,
    gpa: std.mem.Allocator,
    source: std.Io.Dir,
    target: std.Io.Dir,
    sub_path: []const u8,
) !u32 {
    const stat = try source.statFile(io, sub_path, .{});

    if (stat.kind == .file) {
        try source.copyFile(sub_path, target, sub_path, io, .{
            .make_path = true,
        });
        return 1;
    }

    std.debug.assert(stat.kind == .directory);

    const source_sub = try source.openDir(io, sub_path, .{
        .iterate = true,
    });
    defer source_sub.close(io);

    const target_sub = try target.createDirPathOpen(io, sub_path, .{});
    defer target_sub.close(io);

    var walker = try source_sub.walk(gpa);
    defer walker.deinit();

    var copied: u32 = 0;

    while (try walker.next(io)) |entry| {
        if (copied == files_max) {
            return error.TooManyFiles;
        }

        switch (entry.kind) {
            .directory => try target_sub.createDirPath(io, entry.path),
            .file => {
                try source_sub.copyFile(entry.path, target_sub, entry.path, io, .{
                    .make_path = true,
                });
                copied += 1;
            },
            else => return error.UnsupportedEntryKind,
        }
    }

    return copied;
}

fn write_version(
    io: std.Io,
    target: std.Io.Dir,
    args: Arguments,
    sha256_hex: *const [64]u8,
    files_copied: u32,
) !void {
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    std.debug.assert(files_copied > 0);
    std.debug.assert(args.keep.len > 0);

    try render_version(&writer, args, sha256_hex, files_copied);
    try target.writeFile(io, .{
        .sub_path = "VERSION.zon",
        .data = writer.buffered(),
    });
}

fn render_version(
    writer: *std.Io.Writer,
    args: Arguments,
    sha256_hex: *const [64]u8,
    files_copied: u32,
) !void {
    std.debug.assert(args.name.len > 0);
    std.debug.assert(sha256_hex.len == 64);

    try writer.print(
        \\.{{
        \\    .name = "{s}",
        \\    .version = "{s}",
        \\    .upstream = "{s}",
        \\    .archive = "{s}",
        \\    .archive_sha256 = "{s}",
        \\    .files = {d},
        \\    .kept = .{{
        \\
    , .{
        args.name,
        args.version,
        args.upstream,
        std.fs.path.basename(args.archive_path),
        sha256_hex,
        files_copied,
    });

    for (args.keep) |keep| try writer.print("        \"{s}\",\n", .{keep});

    try writer.writeAll("    },\n}\n");
}

test "parse_args needs six arguments; the rest is the keep list" {
    const init: std.process.Init = undefined;
    _ = init;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const list = [_][]const u8{
        "/a.tar.gz", "/vendor/x", "x", "1.0", "https://x", "src", "LICENSE",
    };
    const args = try parse_args_with(arena_state.allocator(), &list);

    try std.testing.expectEqualStrings("x", args.name);
    try std.testing.expectEqual(@as(usize, 2), args.keep.len);
    try std.testing.expectEqualStrings("LICENSE", args.keep[1]);
    const short = parse_args_with(arena_state.allocator(), list[0..5]);
    try std.testing.expectError(error.MissingArguments, short);
}

test "render_version writes a ZON manifest with the pins and the keep list" {
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const args: Arguments = .{
        .archive_path = "/tmp/x-1.0.tar.gz",
        .target_root = "/vendor/x",
        .name = "x",
        .version = "1.0",
        .upstream = "https://x",
        .keep = &.{ "src", "LICENSE" },
    };
    const digest: [64]u8 = @splat('a');

    try render_version(&writer, args, &digest, 7);

    const zon = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, zon, ".archive = \"x-1.0.tar.gz\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, zon, ".files = 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, zon, "\"LICENSE\",") != null);
}
