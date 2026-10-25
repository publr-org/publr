//! `publr --site <address> plugin build --name <name>`: the plugin built here, by this
//! binary's compiler, and its module sent to the Publr at `address` (or the work open in
//! this folder) a piece at a time, then enabled when new or applied when it was there. A
//! site that builds nothing itself (Publr Cloud's projects carry no compiler) gets its
//! plugins this way, as one command.
const std = @import("std");
const plugin_build = @import("../plugin_build.zig");
const forwarding = @import("../remote.zig");
const report = @import("../../lib/report.zig");

/// Raw bytes per piece: base64 of it stays well under `/api/cli`'s 1 MiB body.
const piece_bytes_max: u32 = 384 << 10;
const module_bytes_max: u32 = 16 << 20;
const builds_dir = ".publr/builds";

pub fn run(
    init: std.process.Init,
    address: []const u8,
    args: []const []const u8,
    production: bool,
    out: *std.Io.Writer,
) !u8 {
    std.debug.assert(address.len > 0);
    std.debug.assert(args.len < 1 << 16);

    const arena = init.arena.allocator();
    const request = plugin_build.parse(arena, args) orelse {
        report.err("usage: publr --site <address> plugin build --name <name> " ++
            "[--dir <folder>]", .{});
        return 2;
    };

    if (request.out != null) {
        report.err("publr plugin build: --out builds here; leave out --site", .{});
        return 2;
    }

    try std.Io.Dir.cwd().createDirPath(init.io, builds_dir);

    const built = try std.fmt.allocPrint(arena, "{s}/{s}.wasm", .{ builds_dir, request.name });

    if (!try plugin_build.built_module(init, request, built)) {
        return 1;
    }

    const limit: std.Io.Limit = .limited(module_bytes_max);
    const bytes = std.Io.Dir.cwd().readFileAlloc(init.io, built, arena, limit) catch |err| {
        report.err("publr plugin build: {s} could not be read: {t}", .{ built, err });
        return 1;
    };
    const site: Site = .{
        .init = init,
        .address = address,
        .production = production,
    };
    var answer: std.Io.Writer.Allocating = .init(arena);

    if (try upload(site, request.name, bytes, &answer.writer) != 0) {
        return 1;
    }

    const update = std.mem.indexOf(u8, answer.written(), "\"update\": true") != null;
    const next = if (update)
        [_][]const u8{ "plugin", "update", "--name", request.name }
    else
        [_][]const u8{ "plugin", "enable", "--names", request.name };

    return forwarding.forward(init, address, &next, production, out);
}

const Site = struct {
    init: std.process.Init,
    address: []const u8,
    production: bool,
};

/// The module sent as `plugin upload` pieces; the last one's answer in `answer`.
fn upload(site: Site, name: []const u8, bytes: []const u8, answer: *std.Io.Writer) !u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(bytes.len <= module_bytes_max);

    const arena = site.init.arena.allocator();
    const encoder = std.base64.standard.Encoder;
    const file = try std.fmt.allocPrint(arena, "{s}.wasm", .{name});
    const encoded = try arena.alloc(u8, encoder.calcSize(piece_bytes_max));
    const whole: u32 = @intCast(bytes.len);
    const pieces: u32 = @max(1, (whole + piece_bytes_max - 1) / piece_bytes_max);

    std.debug.assert(pieces <= module_bytes_max / piece_bytes_max + 1);

    for (0..pieces) |index| {
        const offset: u32 = @as(u32, @intCast(index)) * piece_bytes_max;
        const end: u32 = @min(offset + piece_bytes_max, whole);
        const last = index + 1 == pieces;
        const at = try std.fmt.allocPrint(arena, "{d}", .{offset});
        const data = encoder.encode(encoded, bytes[offset..end]);
        const words = [_][]const u8{
            "plugin",   "upload",
            "--file",   file,
            "--offset", at,
            "--data",   data,
            "--last",   if (last) "true" else "false",
        };
        var discarded: std.Io.Writer.Discarding = .init(&.{});
        const into = if (last) answer else &discarded.writer;
        const code = try forwarding.forward(site.init, site.address, &words, site.production, into);

        if (code != 0) {
            return code;
        }
    }

    return 0;
}
