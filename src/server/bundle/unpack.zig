const std = @import("std");
const backup = @import("../gate/backup.zig");
const bundle = @import("../bundle.zig");

const manifest_bytes_max: u32 = 64 << 10;
const copy_buffer_bytes: u32 = 64 << 10;

pub const Options = struct {
    /// The most the files may hold once unpacked; a bundle past it is refused.
    bytes_max: u64 = 64 << 30,
    /// Raised by every file's bytes as it is written, for someone watching.
    written: ?*std.atomic.Value(u64) = null,
    /// False: media files are passed over (a clone's merge base holds the site without them).
    media: bool = true,
};

/// The bundle at `bundle_path` (a gzipped tar: a branch pushed to this site, a pack a
/// clone made) written out as `site`, with every check `import_from` makes.
pub fn unpack(
    site: backup.Site,
    arena: std.mem.Allocator,
    bundle_path: []const u8,
    options: Options,
) !bundle.Manifest {
    std.debug.assert(bundle_path.len > 0);
    std.debug.assert(options.bytes_max > 0);

    const io = site.io;
    const cwd = std.Io.Dir.cwd();
    const database = try std.fs.path.join(arena, &.{ site.data_dir, site.database });

    if (cwd.access(io, database, .{})) |_| {
        return error.SiteExists;
    } else |_| {}

    errdefer cwd.deleteFile(io, database) catch |err| {
        std.log.debug("removing the unfinished {s}: {t}", .{ database, err });
    };

    var file = try cwd.openFile(io, bundle_path, .{});
    defer file.close(io);
    var file_buffer: [copy_buffer_bytes]u8 = undefined;
    var file_reader = file.reader(io, &file_buffer);
    const window = try std.heap.page_allocator.alloc(u8, std.compress.flate.max_window_len);
    defer std.heap.page_allocator.free(window);
    var decompress: std.compress.flate.Decompress = .init(&file_reader.interface, .gzip, window);
    var name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var entries: std.tar.Iterator = .init(&decompress.reader, .{
        .file_name_buffer = &name_buffer,
        .link_name_buffer = &link_buffer,
    });
    const manifest = try read_manifest(arena, &entries);
    var landing: Landing = .{
        .site = site,
        .arena = arena,
        .manifest = manifest,
        .database = database,
        .options = options,
    };

    while (try entries.next()) |entry| {
        if (entry.kind == .sym_link) {
            return error.InvalidBundle;
        }

        const target = try landing.place(entry.name, entry.kind == .directory, entry.size) orelse
            continue;
        const writing = try Writing.open(site.io, target);
        defer writing.close(site.io);

        try entries.streamRemaining(entry, &writing.writer.interface);
        try landing.written(writing, entry.size);
    }

    try landing.finish();

    return manifest;
}

/// The bundle's files, unpacked in `folder` (as `site import` and `export_to` lay them),
/// taken in as `site`: `data/` into its data folder (the database under the site's own
/// name), `site/` into its project folder. Refused when the site has a database already,
/// for a manifest of another format or a newer version, and for a name that would land
/// outside the two folders, a link, or more than `bytes_max`. A refused import leaves no
/// database behind, so it can be tried again. The folder stays as it was.
pub fn import_from(
    site: backup.Site,
    arena: std.mem.Allocator,
    folder: []const u8,
    options: Options,
) !bundle.Manifest {
    std.debug.assert(folder.len > 0);
    std.debug.assert(options.bytes_max > 0);

    const io = site.io;
    const cwd = std.Io.Dir.cwd();
    const database = try std.fs.path.join(arena, &.{ site.data_dir, site.database });

    if (cwd.access(io, database, .{})) |_| {
        return error.SiteExists;
    } else |_| {}

    errdefer cwd.deleteFile(io, database) catch |err| {
        std.log.debug("removing the unfinished {s}: {t}", .{ database, err });
    };

    var root = cwd.openDir(io, folder, .{
        .iterate = true,
    }) catch return error.NotABundle;
    defer root.close(io);

    const limit: std.Io.Limit = .limited(manifest_bytes_max);
    const about = root.readFileAlloc(io, bundle.manifest_name, arena, limit) catch
        return error.NotABundle;
    const manifest = try parse_manifest(arena, about);
    var landing: Landing = .{
        .site = site,
        .arena = arena,
        .manifest = manifest,
        .database = database,
        .options = options,
    };
    var walker = try root.walk(arena);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind == .sym_link) {
            return error.InvalidBundle;
        }

        if (entry.kind != .file) {
            continue;
        }

        const name = try arena.dupe(u8, entry.path);

        std.mem.replaceScalar(u8, name, std.fs.path.sep, '/');

        if (std.mem.eql(u8, name, bundle.manifest_name)) {
            continue;
        }

        var source = try root.openFile(io, entry.path, .{});
        defer source.close(io);
        var source_buffer: [copy_buffer_bytes]u8 = undefined;
        var reader = source.reader(io, &source_buffer);
        const size = try reader.getSize();
        const target = try landing.place(name, false, size) orelse continue;
        const writing = try Writing.open(io, target);
        defer writing.close(io);

        _ = try reader.interface.streamRemaining(&writing.writer.interface);
        try landing.written(writing, size);
    }

    try landing.finish();

    return manifest;
}

fn read_manifest(arena: std.mem.Allocator, entries: *std.tar.Iterator) !bundle.Manifest {
    std.debug.assert(entries.unread_file_bytes == 0);
    std.debug.assert(manifest_bytes_max > 0);

    const first = (entries.next() catch return error.NotABundle) orelse return error.NotABundle;

    if (!std.mem.eql(u8, first.name, bundle.manifest_name) or first.size > manifest_bytes_max) {
        return error.NotABundle;
    }

    const about = try arena.alloc(u8, @intCast(first.size));

    try entries.reader.readSliceAll(about);
    entries.unread_file_bytes = 0;

    return parse_manifest(arena, about);
}

fn parse_manifest(arena: std.mem.Allocator, about: []const u8) !bundle.Manifest {
    std.debug.assert(manifest_bytes_max > 0);

    if (about.len > manifest_bytes_max) {
        return error.NotABundle;
    }

    const manifest = std.json.parseFromSliceLeaky(bundle.Manifest, arena, about, .{
        .ignore_unknown_fields = true,
    }) catch return error.NotABundle;

    if (!std.mem.eql(u8, manifest.format, bundle.format_name) or !safe_name(manifest.database)) {
        return error.NotABundle;
    }

    if (manifest.version > bundle.format_version) {
        return error.NewerBundle;
    }

    return manifest;
}

/// Where each file of a bundle lands, and the checks on the way: names inside the site's
/// two folders, the size cap, media passed over when asked, the database there at the end.
const Landing = struct {
    site: backup.Site,
    arena: std.mem.Allocator,
    manifest: bundle.Manifest,
    /// The site's own database file.
    database: []const u8,
    options: Options,
    bytes: u64 = 0,
    has_database: bool = false,

    /// Where `name` goes, its folder made; null when it is passed over (a folder, or media
    /// not wanted). Refused for a name outside the two folders or past the cap.
    fn place(landing: *Landing, name: []const u8, directory: bool, size: u64) !?[]const u8 {
        std.debug.assert(landing.options.bytes_max > 0);

        const target = try target_of(landing.site, landing.arena, landing.manifest, name) orelse
            return error.InvalidBundle;

        if (directory) {
            try std.Io.Dir.cwd().createDirPath(landing.site.io, target);
            return null;
        }

        landing.bytes = std.math.add(u64, landing.bytes, size) catch return error.TooLarge;

        if (landing.bytes > landing.options.bytes_max) {
            return error.TooLarge;
        }

        landing.has_database = landing.has_database or std.mem.eql(u8, target, landing.database);

        if (!landing.options.media and std.mem.startsWith(u8, name, "data/media/")) {
            return null;
        }

        if (std.fs.path.dirname(target)) |parent| {
            try std.Io.Dir.cwd().createDirPath(landing.site.io, parent);
        }

        return target;
    }

    fn written(landing: *Landing, writing: *Writing, size: u64) !void {
        try writing.writer.interface.flush();

        if (landing.options.written) |counter| {
            _ = counter.fetchAdd(size, .release);
        }
    }

    fn finish(landing: *const Landing) !void {
        if (!landing.has_database) {
            return error.InvalidBundle;
        }
    }
};

/// One file being written, never over another; the secrets' key its owner's alone, as it was
/// made.
const Writing = struct {
    file: std.Io.File,
    buffer: [copy_buffer_bytes]u8,
    writer: std.Io.File.Writer,

    fn open(io: std.Io, target: []const u8) !*Writing {
        std.debug.assert(target.len > 0);

        const private = std.mem.eql(u8, std.fs.path.basename(target), "secret.key");
        const writing = try std.heap.page_allocator.create(Writing);
        errdefer std.heap.page_allocator.destroy(writing);

        writing.file = try std.Io.Dir.cwd().createFile(io, target, .{
            .exclusive = true,
            .permissions = if (private) .fromMode(0o600) else .default_file,
        });
        writing.writer = writing.file.writer(io, &writing.buffer);

        return writing;
    }

    fn close(writing: *Writing, io: std.Io) void {
        writing.file.close(io);
        std.heap.page_allocator.destroy(writing);
    }
};

/// Where a bundle's `name` goes: `data/<path>` under the data folder (its database under
/// the site's own name), `site/<item>/...` under the project folder for the project's
/// items; null for anything else, or a name that climbs out.
pub fn target_of(
    site: backup.Site,
    arena: std.mem.Allocator,
    manifest: bundle.Manifest,
    name: []const u8,
) !?[]const u8 {
    std.debug.assert(site.database.len > 0);
    std.debug.assert(manifest.database.len > 0);

    if (!safe_name(name)) {
        return null;
    }

    const trimmed = std.mem.trimEnd(u8, name, "/");

    if (std.mem.startsWith(u8, trimmed, "data/")) {
        const rest = trimmed["data/".len..];
        const own = if (std.mem.eql(u8, rest, manifest.database)) site.database else rest;

        return try std.fs.path.join(arena, &.{ site.data_dir, own });
    }

    if (!std.mem.startsWith(u8, trimmed, "site/")) {
        return null;
    }

    const rest = trimmed["site/".len..];
    const item = rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];

    for (bundle.project_items) |known| {
        if (std.mem.eql(u8, item, known)) {
            return try std.fs.path.join(arena, &.{ site.project_dir, rest });
        }
    }

    return null;
}

/// Relative, `/`-separated, with no empty, `.` or `..` part and no backslash.
fn safe_name(name: []const u8) bool {
    std.debug.assert(name.len <= std.fs.max_path_bytes);

    if (name.len == 0 or name[0] == '/' or std.mem.indexOfScalar(u8, name, '\\') != null) {
        return false;
    }

    var parts = std.mem.splitScalar(u8, std.mem.trimEnd(u8, name, "/"), '/');

    while (parts.next()) |part| {
        const empty_or_dots = part.len == 0 or std.mem.eql(u8, part, ".") or
            std.mem.eql(u8, part, "..");

        if (empty_or_dots) {
            return false;
        }
    }

    std.debug.assert(name[0] != '/');

    return true;
}

test "a bundle's names land in the site's two folders, nowhere else" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const site: backup.Site = .{
        .io = std.testing.io,
        .database = "site.db",
        .data_dir = "/site/data",
        .project_dir = "/site",
    };
    const manifest: bundle.Manifest = .{
        .release = "",
        .name = "ada",
        .made_at_ms = 1,
        .database = "publr.db",
    };
    const Case = struct {
        []const u8,
        ?[]const u8,
    };
    const cases = [_]Case{
        .{ "data/publr.db", "/site/data/site.db" },
        .{ "data/media/a/photo.webp", "/site/data/media/a/photo.webp" },
        .{ "site/apps/www/app.zon", "/site/apps/www/app.zon" },
        .{ "site/publr.zon", "/site/publr.zon" },
        .{ "site/output/index.html", null },
        .{ "site/site.json", null },
        .{ "data/../../etc/passwd", null },
        .{ "data/media/./x", null },
        .{ "/etc/passwd", null },
        .{ "data//x", null },
        .{ "data\\x", null },
        .{ "elsewhere/x", null },
        .{ "", null },
    };

    for (cases) |case| {
        const found = try target_of(site, arena, manifest, case[0]);

        if (case[1]) |expected| {
            try std.testing.expectEqualStrings(expected, found.?);
        } else {
            try std.testing.expect(found == null);
        }
    }
}
