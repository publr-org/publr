//! `admin_asset_version <out.zig> <file or folder>...`: one version for every file the admin
//! serves from `/admin/assets/<version>/`, as `pub const version = "<16 hex>";`. Each file's
//! name and bytes are hashed, and the hashes are added up, so the order a folder lists them
//! in does not matter. Any change to any file is a new version, and browsers that kept the
//! old files for a year ask for the new ones.
const std = @import("std");

const files_max: u32 = 1 << 14;
const file_bytes_max: u32 = 64 << 20;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(arena);

    _ = args.next();

    const out_path = args.next() orelse return usage();
    const cwd = std.Io.Dir.cwd();
    var total: u64 = 0;
    var files: u32 = 0;

    while (args.next()) |input| {
        total +%= try hash_input(init, cwd, input, &files);
    }

    if (files == 0) {
        return usage();
    }

    std.debug.assert(out_path.len > 0);

    var out_buffer: [64]u8 = undefined;
    const source = try std.fmt.bufPrint(&out_buffer, "pub const version = \"{x:0>16}\";\n", .{
        total,
    });

    try cwd.writeFile(init.io, .{
        .sub_path = out_path,
        .data = source,
    });
}

fn usage() error{Usage} {
    std.debug.print("usage: admin_asset_version <out.zig> <file or folder>...\n", .{});

    return error.Usage;
}

/// A file's hash, or the sum of every file's under a folder, by its path inside it.
fn hash_input(init: std.process.Init, cwd: std.Io.Dir, input: []const u8, files: *u32) !u64 {
    std.debug.assert(input.len > 0);
    std.debug.assert(files.* <= files_max);

    var dir = cwd.openDir(init.io, input, .{
        .iterate = true,
    }) catch |err| switch (err) {
        error.NotDir => return hash_file(init, cwd, input, std.fs.path.basename(input), files),
        else => return err,
    };
    defer dir.close(init.io);

    var walker = try dir.walk(init.gpa);
    defer walker.deinit();

    var total: u64 = 0;

    while (try walker.next(init.io)) |entry| {
        if (entry.kind != .file) {
            continue;
        }

        total +%= try hash_file(init, entry.dir, entry.basename, entry.path, files);
    }

    return total;
}

fn hash_file(
    init: std.process.Init,
    dir: std.Io.Dir,
    name: []const u8,
    path: []const u8,
    files: *u32,
) !u64 {
    std.debug.assert(name.len > 0);
    std.debug.assert(path.len > 0);

    if (files.* == files_max) {
        return error.TooManyFiles;
    }

    files.* += 1;

    const bytes = try dir.readFileAlloc(init.io, name, init.gpa, .limited(file_bytes_max));
    defer init.gpa.free(bytes);

    var hash = std.hash.Wyhash.init(0);

    hash.update(path);
    hash.update(&.{0});
    hash.update(bytes);

    return hash.final();
}
