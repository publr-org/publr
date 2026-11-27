//! The SDK sandboxed plugins of this release are built against (`src/`, `stubs/`,
//! `guest.zig`, the views' lowering), carried in the binary for a compiler outside it: the
//! `publr` command's, which runs `plugin prepare` and builds the module itself.
const std = @import("std");
const options = @import("sdk_options");
const report = @import("../lib/report.zig");
const sdk_archive = if (options.sdk) @embedFile("sdk_archive") else "";

/// `publr plugin sdk --out <folder>`: the SDK plugins of this release are built against
/// (`src/`, `stubs/`, `guest.zig`, the views' lowering), written into a new or empty folder,
/// for a compiler outside this binary (the `publr` command's).
pub fn write_sdk(init: std.process.Init, out: *std.Io.Writer, args: []const []const u8) !u8 {
    if (args.len != 2 or !std.mem.eql(u8, args[0], "--out")) {
        report.err("usage: publr plugin sdk --out <folder>", .{});
        return 2;
    }

    if (!options.sdk) {
        report.err("publr plugin sdk: this binary carries no SDK", .{});
        return 1;
    }

    std.debug.assert(sdk_archive.len > 0);

    const folder = args[1];
    const cwd = std.Io.Dir.cwd();

    try cwd.createDirPath(init.io, folder);

    var dir = try cwd.openDir(init.io, folder, .{
        .iterate = true,
    });
    defer dir.close(init.io);
    var iterator = dir.iterate();

    if (try iterator.next(init.io) != null) {
        report.err("publr plugin sdk: {s} is not empty", .{folder});
        return 1;
    }

    try extract_sdk(init.io, dir);
    const version = @import("../publr/version.zig").version;

    try out.print("Wrote the SDK of Publr {s} to {s}\n", .{ version, folder });

    return 0;
}

/// This release's SDK written into `dir`, as `plugin sdk` and `plugin prepare` give it.
pub fn extract_sdk(io: std.Io, dir: std.Io.Dir) !void {
    if (!options.sdk) {
        return error.NoSdk;
    }

    std.debug.assert(sdk_archive.len > 0);

    var input: std.Io.Reader = .fixed(sdk_archive);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var gzip: std.compress.flate.Decompress = .init(&input, .gzip, &window);

    try std.tar.extract(io, dir, &gzip.reader, .{});
}

/// The SDK this binary carries, as 16 hex digits: two builds of one release that carry
/// different SDKs (a development build after a change to the design system) get different
/// copies beside the database, never the other's.
pub fn fingerprint() [16]u8 {
    std.debug.assert(!options.sdk or sdk_archive.len > 0);

    return std.fmt.hex(std.hash.Wyhash.hash(0, sdk_archive));
}
