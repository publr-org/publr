//! A whole site in one file, to move it to another host (Publr Cloud's deploy, and back):
//! a gzipped POSIX tar, `<name>.site.tar.gz`, laid out as the gate's backups are.
//!
//! ```
//! publr-site.json   the manifest, always first
//! data/publr.db     the database: a consistent snapshot, this machine's rows taken out
//! data/...          media, installed plugins (`plugins/<hash>.wasm`), the secrets' key
//! site/...          the project folder's publr.zon, apps/ and plugins/ (their sources)
//! ```
//!
//! What only this machine needs stays behind: sessions, devices, used sign-on tokens and
//! whom the site trusts to sign people in, live agents, the build index, caches, backups,
//! agents' logs, plugin builds, the serve marker, built pages, and the project folder's
//! other files. Unpacking never writes over a site.
const std = @import("std");
const report = @import("../lib/report.zig");
const backup = @import("gate/backup.zig");
const operator = @import("operator.zig");

pub const pack = @import("bundle/pack.zig").pack;
pub const unpack = @import("bundle/unpack.zig").unpack;
pub const UnpackOptions = @import("bundle/unpack.zig").Options;

pub const format_name = "publr-site";
pub const format_version: u32 = 1;
pub const manifest_name = "publr-site.json";
pub const extension = ".site.tar.gz";
/// What the project folder holds that a site is.
pub const project_items = [_][]const u8{ "publr.zon", "apps", "plugins" };

pub const Manifest = struct {
    format: []const u8 = format_name,
    version: u32 = format_version,
    /// The Publr that packed it.
    publr: []const u8 = @import("../publr.zig").version,
    /// The release that last opened the database; empty when none recorded one.
    release: []const u8,
    name: []const u8,
    made_at_ms: i64,
    /// The database's file name under `data/`.
    database: []const u8,
};

pub const Packed = struct {
    manifest: Manifest,
    files: u32,
    /// Bytes before compression.
    bytes: u64,
};

pub const help =
    \\  pack [<file>]     The site in this folder as one file, `<folder>.site.tar.gz` unless
    \\                    named; safe while `serve` runs
    \\  unpack <file>     A packed site written into this folder, which must have none
    \\
;

/// `publr pack [<file>]` and `publr unpack <file>`.
pub fn run(
    init: std.process.Init,
    out: *std.Io.Writer,
    db_path: [:0]const u8,
    args: []const []const u8,
) !u8 {
    std.debug.assert(args.len > 0);
    std.debug.assert(db_path.len > 0);

    const packing = std.mem.eql(u8, args[0], "pack") and args.len <= 2;
    const unpacking = std.mem.eql(u8, args[0], "unpack") and args.len == 2;

    if (packing) {
        return pack_here(init, out, db_path, if (args.len == 2) args[1] else null);
    }

    if (unpacking) {
        return unpack_here(init, out, db_path, args[1]);
    }

    try out.print("usage:\n{s}", .{help});

    return 2;
}

/// Whether `args` is one of these commands.
pub fn handles(args: []const []const u8) bool {
    std.debug.assert(args.len > 0);
    std.debug.assert(args.len <= 128);

    return std.mem.eql(u8, args[0], "pack") or std.mem.eql(u8, args[0], "unpack");
}

fn pack_here(
    init: std.process.Init,
    out: *std.Io.Writer,
    db_path: [:0]const u8,
    named: ?[]const u8,
) !u8 {
    std.debug.assert(db_path.len > 0);
    std.debug.assert(extension.len > 0);

    const arena = init.arena.allocator();
    const site = backup.Site.of(init.io, arena, db_path, null) catch |err| {
        report.err("publr pack: no site here ({s}: {t})", .{ db_path, err });
        return 1;
    };
    const name = std.fs.path.basename(site.project_dir);
    const file = named orelse try std.fmt.allocPrint(arena, "{s}{s}", .{ name, extension });
    const made = try pack(site, arena, file, name);
    const stat = try std.Io.Dir.cwd().statFile(init.io, file, .{});

    try out.print("Packed {s}: {d} files, {d} KiB ({d} KiB unpacked)\n", .{
        file,
        made.files,
        stat.size / 1024,
        made.bytes / 1024,
    });

    return 0;
}

fn unpack_here(
    init: std.process.Init,
    out: *std.Io.Writer,
    db_path: [:0]const u8,
    file: []const u8,
) !u8 {
    std.debug.assert(db_path.len > 0);
    std.debug.assert(file.len > 0);

    const arena = init.arena.allocator();

    if (try operator.find(init.io, arena, db_path)) |running| {
        report.err("publr unpack: a server runs for {s} on port {d}", .{ db_path, running.port });
        return 1;
    }

    const parent = std.fs.path.dirname(db_path) orelse ".";

    try std.Io.Dir.cwd().createDirPath(init.io, if (parent.len == 0) "." else parent);

    const site = try backup.Site.of(init.io, arena, db_path, null);
    const manifest = unpack(site, arena, file, .{}) catch |err| {
        const why = switch (err) {
            error.SiteExists => "this folder has a site already; unpack into an empty one",
            error.NewerBundle => "it was packed by a newer Publr; update this one first",
            error.NotABundle, error.InvalidBundle => "it is not a packed site",
            else => @errorName(err),
        };

        report.err("publr unpack: {s}: {s}", .{ file, why });
        return 1;
    };

    try out.print("Unpacked {s} (packed by Publr {s}) into {s}\n", .{
        manifest.name,
        manifest.publr,
        site.project_dir,
    });

    return 0;
}

test {
    _ = @import("bundle/pack.zig");
    _ = @import("bundle/unpack.zig");
    _ = @import("bundle/bundle_test.zig");
}
