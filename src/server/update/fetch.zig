//! Publr's releases, fetched from where they are published: the list, and one release's
//! files for this machine. `PUBLR_RELEASES_URL` and `PUBLR_RELEASES_API` point elsewhere
//! (a mirror, a test server); the signature is checked whatever the source.

const std = @import("std");
const release = @import("../../model/release.zig");

const version = @import("../../publr.zig").version;
const downloads_default = "https://github.com/" ++ release.repository ++ "/releases/download";
const listing_default = "https://api.github.com/repos/" ++ release.repository ++
    "/releases?per_page=100";
const listing_bytes_max: u32 = 8 << 20;
const sums_name = "SHA256SUMS";
const signature_name = "SHA256SUMS.sig";

/// Where releases come from: Publr's GitHub, unless the environment names another.
pub const Source = struct {
    downloads: []const u8 = downloads_default,
    listing: []const u8 = listing_default,

    pub fn of(environ_map: anytype) Source {
        std.debug.assert(downloads_default.len > 0);

        const downloads = environ_map.get("PUBLR_RELEASES_URL") orelse "";
        const listing = environ_map.get("PUBLR_RELEASES_API") orelse "";

        return .{
            .downloads = if (downloads.len == 0) downloads_default else downloads,
            .listing = if (listing.len == 0) listing_default else listing,
        };
    }
};

/// The releases newer than this one, newest first; null when they could not be reached.
pub fn releases(io: std.Io, arena: std.mem.Allocator, source: Source) ?[]const release.Release {
    std.debug.assert(listing_bytes_max > 0);
    std.debug.assert(version.len > 0);

    const url = source.listing;
    var body: std.Io.Writer.Allocating = .init(arena);

    get(io, url, &body.writer) catch |err| {
        std.log.warn("releases from {s}: {t}", .{ url, err });
        return null;
    };

    return release.newer_in(arena, body.written(), version) catch |err| {
        std.log.warn("releases from {s}: {t}", .{ url, err });
        return null;
    };
}

/// This machine's binary of `target`, its checksums and their signature, into `folder`.
pub fn release_files(
    io: std.Io,
    arena: std.mem.Allocator,
    source: Source,
    target: []const u8,
    folder: []const u8,
) !void {
    std.debug.assert(target.len > 0);
    std.debug.assert(folder.len > 0);

    const base = source.downloads;
    const cwd = std.Io.Dir.cwd();

    try cwd.deleteTree(io, folder);
    try cwd.createDirPath(io, folder);

    for ([_][]const u8{ release.asset_name(), sums_name, signature_name }) |name| {
        const url = try std.fmt.allocPrint(arena, "{s}/v{s}/{s}", .{ base, target, name });
        const path = try std.fs.path.join(arena, &.{ folder, name });
        // The binary is run straight from here, for the rehearsal.
        const executable = std.mem.eql(u8, name, release.asset_name());
        var file = try cwd.createFile(io, path, .{
            .permissions = if (executable) .executable_file else .default_file,
        });
        defer file.close(io);
        var buffer: [64 << 10]u8 = undefined;
        var writer = file.writer(io, &buffer);

        try get(io, url, &writer.interface);
        try writer.interface.flush();
    }
}

/// Null when the files in `folder` are what Publr published: the checksums signed with its
/// key, and the binary's SHA-256 the one they list. Else why not.
pub fn verified(io: std.Io, arena: std.mem.Allocator, folder: []const u8) ?[]const u8 {
    std.debug.assert(folder.len > 0);
    std.debug.assert(release.signing_key_hex.len == 64);

    const sums = read(io, arena, folder, sums_name) orelse return "no checksums";
    const signature = read(io, arena, folder, signature_name) orelse return "no signature";

    if (!release.signed(sums, signature, release.signing_key_hex)) {
        return "the checksums' signature is not Publr's";
    }

    const expected = release.sum_of(sums, release.asset_name()) orelse
        return "the checksums do not list this machine's binary";
    const binary = read(io, arena, folder, release.asset_name()) orelse return "no binary";
    var digest: [32]u8 = undefined;

    std.crypto.hash.sha2.Sha256.hash(binary, &digest, .{});

    const actual = std.fmt.bytesToHex(digest, .lower);

    if (!std.mem.eql(u8, &actual, expected)) {
        return "the binary is not the one the checksums list";
    }

    return null;
}

fn read(io: std.Io, arena: std.mem.Allocator, folder: []const u8, name: []const u8) ?[]const u8 {
    std.debug.assert(name.len > 0);

    const path = std.fs.path.join(arena, &.{ folder, name }) catch return null;

    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(512 << 20)) catch null;
}

fn get(io: std.Io, url: []const u8, out: *std.Io.Writer) !void {
    std.debug.assert(url.len > 0);

    // Its own memory: TLS loads the system's certificates, more than a request holds.
    var client_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer client_arena.deinit();
    var client: std.http.Client = .{
        .allocator = client_arena.allocator(),
        .io = io,
    };
    defer client.deinit();

    const result = try client.fetch(.{
        .location = .{
            .url = url,
        },
        .method = .GET,
        .keep_alive = false,
        .extra_headers = &.{
            .{
                .name = "User-Agent",
                .value = "publr/" ++ version,
            },
            .{
                .name = "Accept",
                .value = "application/vnd.github+json",
            },
        },
        .response_writer = out,
    });

    if (result.status != .ok) {
        std.log.warn("GET {s}: {d}", .{ url, @intFromEnum(result.status) });
        return error.NotFound;
    }
}
