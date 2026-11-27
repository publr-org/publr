//! A whole site, to move it to another computer: `site export` writes it into a folder,
//! `site import` takes one in, and a site hands it out to a clone (`clone/site.zig`) or
//! takes a pushed branch in (the environments plugin) as a gzipped POSIX tar. The archive
//! file (`<name>.site.tar.gz`) around an export is the `publr` command's (`pack`, `unpack`,
//! `deploy`). Laid out as the gate's backups are:
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
//! other files. Importing never writes over a site.
const std = @import("std");
const report = @import("../lib/report.zig");
const backup = @import("gate/backup.zig");
const operator = @import("operator.zig");

pub const pack_clone = @import("bundle/pack.zig").pack_clone;
pub const PackProgress = @import("bundle/pack.zig").Progress;
pub const snapshot_suffix = @import("bundle/pack.zig").snapshot_suffix;
pub const export_to = @import("bundle/pack.zig").export_to;
pub const unpack = @import("bundle/unpack.zig").unpack;
pub const import_from = @import("bundle/unpack.zig").import_from;
pub const Clone = @import("bundle/clone.zig").Clone;
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
    publr: []const u8 = @import("../publr/version.zig").version,
    /// The release that last opened the database; empty when none recorded one.
    release: []const u8,
    name: []const u8,
    made_at_ms: i64,
    /// The database's file name under `data/`.
    database: []const u8,
    /// Media storage keys whose files it leaves out: the folder it came from held only
    /// placeholders, so whoever unpacks it takes them from its own source.
    placeholders: []const []const u8 = &.{},
    /// The site's newest activity entry when it was packed (`store/activity.zig`'s `latest`):
    /// a clone asks later whether the site moved past it.
    latest_change: i64 = 0,
};

pub const Packed = struct {
    manifest: Manifest,
    files: u32,
    /// Bytes before compression.
    bytes: u64,
    /// The same bytes by what they are, for someone watching the bundle travel.
    parts: Parts = .{},
};

/// A bundle's bytes before compression, by part: the database (and the data folder's other
/// files), media, apps, plugins (sources and installed modules).
pub const Parts = struct {
    database: u64 = 0,
    media: u64 = 0,
    apps: u64 = 0,
    plugins: u64 = 0,

    pub fn count(parts: *Parts, name: []const u8, bytes: u64) void {
        std.debug.assert(name.len > 0);

        const starts = std.mem.startsWith;
        const part = if (starts(u8, name, "data/media/"))
            &parts.media
        else if (starts(u8, name, "site/apps/"))
            &parts.apps
        else if (starts(u8, name, "site/plugins/") or starts(u8, name, "data/plugins/"))
            &parts.plugins
        else
            &parts.database;

        part.* += bytes;
    }
};

pub const help =
    \\  site export --to <folder> [--clone] [--no-media] [--placeholders <file>]
    \\                    The site's files for another computer, unpacked into a new or
    \\                    empty folder (this computer's rows left out); safe while `serve`
    \\                    runs. --clone: without its people, logs and secrets, as a clone
    \\                    is; --no-media: no media files; --placeholders: a file of media
    \\                    storage keys, one a line, whose files stay behind
    \\  site import --from <folder> [--no-media] [--keep-local <database>]
    \\                    An exported site taken into this folder, which must have none;
    \\                    --keep-local: this computer's rows (sign-on, sessions, devices)
    \\                    carried over from that database, for the accounts it still has
    \\
;

/// `publr site export`, `import`, `state` and `placeholders`.
pub fn run(
    init: std.process.Init,
    out: *std.Io.Writer,
    db_path: [:0]const u8,
    args: []const []const u8,
) !u8 {
    std.debug.assert(args.len > 0);
    std.debug.assert(db_path.len > 0);

    if (std.mem.eql(u8, args[0], "site") and args.len > 1) {
        if (std.mem.eql(u8, args[1], "export")) {
            return export_here(init, out, db_path, args[2..]);
        }

        if (std.mem.eql(u8, args[1], "import")) {
            return import_here(init, out, db_path, args[2..]);
        }

        if (std.mem.eql(u8, args[1], "state")) {
            return @import("bundle/state.zig").state(init, out, db_path, args[2..]);
        }

        if (std.mem.eql(u8, args[1], "placeholders")) {
            return @import("bundle/state.zig").write_placeholders(init, out, db_path, args[2..]);
        }
    }

    try out.print("usage:\n{s}{s}", .{ help, @import("bundle/state.zig").help });

    return 2;
}

/// Whether `args` is one of these commands.
pub fn handles(args: []const []const u8) bool {
    std.debug.assert(args.len > 0);
    std.debug.assert(args.len <= 128);

    const site = args.len > 1 and std.mem.eql(u8, args[0], "site") and
        (std.mem.eql(u8, args[1], "export") or std.mem.eql(u8, args[1], "import") or
            std.mem.eql(u8, args[1], "state") or std.mem.eql(u8, args[1], "placeholders"));

    return site;
}

const ExportArgs = struct {
    to: []const u8 = "",
    clone: bool = false,
    media: bool = true,
    placeholders: []const u8 = "",
};

fn export_args(args: []const []const u8) ?ExportArgs {
    std.debug.assert(args.len < 1 << 16);

    var parsed: ExportArgs = .{};
    var index: usize = 0;

    while (index < args.len) : (index += 1) {
        const word = args[index];
        const valued = index + 1 < args.len;

        if (std.mem.eql(u8, word, "--to") and valued) {
            index += 1;
            parsed.to = args[index];
        } else if (std.mem.eql(u8, word, "--placeholders") and valued) {
            index += 1;
            parsed.placeholders = args[index];
        } else if (std.mem.eql(u8, word, "--clone")) {
            parsed.clone = true;
        } else if (std.mem.eql(u8, word, "--no-media")) {
            parsed.media = false;
        } else {
            return null;
        }
    }

    if (parsed.to.len == 0) {
        return null;
    }

    return parsed;
}

/// `publr site export --to <folder> ...`.
fn export_here(
    init: std.process.Init,
    out: *std.Io.Writer,
    db_path: [:0]const u8,
    args: []const []const u8,
) !u8 {
    std.debug.assert(db_path.len > 0);

    const parsed = export_args(args) orelse {
        try out.print("usage:\n{s}", .{help});
        return 2;
    };
    const arena = init.arena.allocator();
    const site = backup.Site.of(init.io, arena, db_path, null) catch |err| {
        report.err("publr site export: no site here ({s}: {t})", .{ db_path, err });
        return 1;
    };
    const clone: ?Clone = if (parsed.clone or !parsed.media or parsed.placeholders.len > 0) .{
        .media = parsed.media,
        .placeholders = try keys_in(init, parsed.placeholders),
    } else null;
    const name = std.fs.path.basename(site.project_dir);
    const made = export_to(site, arena, parsed.to, name, clone) catch |err| {
        const why = switch (err) {
            error.FolderNotEmpty => "the folder is not empty",
            error.FolderInsideSite => "the folder is inside the site's data folder",
            else => @errorName(err),
        };

        report.err("publr site export: {s}: {s}", .{ parsed.to, why });
        return 1;
    };

    try out.print("Exported {s} to {s}: {d} files, {d} KiB\n", .{
        made.manifest.name,
        parsed.to,
        made.files,
        made.bytes / 1024,
    });

    return 0;
}

/// Media storage keys, one a line, from `path`; none for an empty path.
fn keys_in(init: std.process.Init, path: []const u8) ![]const []const u8 {
    std.debug.assert(path.len <= std.fs.max_path_bytes);

    if (path.len == 0) {
        return &.{};
    }

    const arena = init.arena.allocator();
    const text = try std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, .limited(16 << 20));
    var keys: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");

    while (lines.next()) |line| {
        try keys.append(arena, line);
    }

    return keys.items;
}

/// `publr site import --from <folder> [--no-media]`.
fn import_here(
    init: std.process.Init,
    out: *std.Io.Writer,
    db_path: [:0]const u8,
    args: []const []const u8,
) !u8 {
    std.debug.assert(db_path.len > 0);

    var from: []const u8 = "";
    var keep_local: []const u8 = "";
    var media = true;
    var index: usize = 0;

    while (index < args.len) : (index += 1) {
        const valued = index + 1 < args.len;

        if (std.mem.eql(u8, args[index], "--from") and valued) {
            index += 1;
            from = args[index];
        } else if (std.mem.eql(u8, args[index], "--keep-local") and valued) {
            index += 1;
            keep_local = args[index];
        } else if (std.mem.eql(u8, args[index], "--no-media")) {
            media = false;
        } else {
            from = "";
            break;
        }
    }

    if (from.len == 0) {
        try out.print("usage:\n{s}", .{help});
        return 2;
    }

    const arena = init.arena.allocator();

    if (try operator.find(init.io, arena, db_path)) |running| {
        const port = running.port;

        report.err("publr site import: a server runs for {s} on port {d}", .{ db_path, port });
        return 1;
    }

    const parent = std.fs.path.dirname(db_path) orelse ".";

    try std.Io.Dir.cwd().createDirPath(init.io, if (parent.len == 0) "." else parent);

    const site = try backup.Site.of(init.io, arena, db_path, null);
    const manifest = import_from(site, arena, from, .{
        .media = media,
    }) catch |err| {
        report.err("publr site import: {s}: {s}", .{ from, refusal(err) });
        return 1;
    };

    if (keep_local.len > 0) {
        const database = try std.fs.path.joinZ(arena, &.{ site.data_dir, site.database });

        try @import("bundle/keep_local.zig").keep_local_rows_of(keep_local, database);
    }

    try out.print("Imported {s} (exported by Publr {s}) into {s}\n", .{
        manifest.name,
        manifest.publr,
        site.project_dir,
    });

    return 0;
}

fn refusal(err: anyerror) []const u8 {
    std.debug.assert(@errorName(err).len > 0);

    return switch (err) {
        error.SiteExists => "this folder has a site already; take it into an empty one",
        error.NewerBundle => "it was made by a newer Publr; update this one first",
        error.NotABundle, error.InvalidBundle => "it is not an exported site",
        error.TooLarge => "it is larger than a site may be",
        else => @errorName(err),
    };
}

test {
    _ = @import("bundle/pack.zig");
    _ = @import("bundle/unpack.zig");
    _ = @import("bundle/clone.zig");
    _ = @import("bundle/bundle_test.zig");
    _ = @import("bundle/state.zig");
}
