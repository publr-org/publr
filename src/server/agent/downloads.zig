//! Files from the web, downloaded in the background by the agent's own process into the
//! media folder (`data/media/<folder>/`), while the turn goes on: the server is not held,
//! and `media sync` takes them all in at once when the agent needs them. A site being moved
//! has its images arriving before the model has planned its first page.

const std = @import("std");
const timed = @import("../../operations/http_timed.zig");
const http_operations = @import("../../operations/http.zig");

/// Files one turn may download, at most.
pub const files_max: u32 = 400;
/// Downloads at once.
pub const workers_max: u32 = 6;
/// One file's size, at most: what the library keeps.
const bytes_max: u32 = 32 << 20;
/// One file's time, at most: a video takes a while, and nothing waits on it but the turn.
const file_timeout_ms: u32 = 120_000;
const name_len_max: u32 = 80;

pub const State = enum { waiting, working, done, failed };

const Item = struct {
    url: []const u8,
    /// `<folder>/<name>`, under the media folder.
    path: []const u8,
    state: State = .waiting,
    why: []const u8 = "",
};

pub const Downloads = struct {
    io: std.Io,
    /// The media folder beside the database.
    root: []const u8,
    mutex: std.Io.Mutex = .init,
    items: [files_max]Item = undefined,
    count: u32 = 0,
    workers: u32 = 0,

    /// Queues `url` into `folder` unless it is queued already, not a public web address,
    /// or the queue is full. Whether it was queued.
    pub fn add(downloads: *Downloads, url: []const u8, folder: []const u8) bool {
        std.debug.assert(folder.len > 0);
        std.debug.assert(downloads.count <= files_max);

        if (!public_url(url)) {
            return false;
        }

        downloads.mutex.lockUncancelable(downloads.io);
        defer downloads.mutex.unlock(downloads.io);

        for (downloads.items[0..downloads.count]) |item| {
            if (std.mem.eql(u8, item.url, url)) {
                return false;
            }
        }

        if (downloads.count == files_max) {
            return false;
        }

        const allocator = std.heap.page_allocator;
        const kept_url = allocator.dupe(u8, url) catch return false;
        const path = path_of(allocator, folder, url, downloads.count) catch return false;

        downloads.items[downloads.count] = .{
            .url = kept_url,
            .path = path,
        };
        downloads.count += 1;

        if (downloads.workers < workers_max) {
            const thread = std.Thread.spawn(.{}, work, .{downloads}) catch return true;

            thread.detach();
            downloads.workers += 1;
        }

        return true;
    }

    /// How the downloads stand, in words for the model: counts and every failure.
    pub fn status(downloads: *Downloads, arena: std.mem.Allocator) ![]const u8 {
        std.debug.assert(downloads.count <= files_max);

        downloads.mutex.lockUncancelable(downloads.io);
        defer downloads.mutex.unlock(downloads.io);

        var counts = [_]u32{0} ** 4;
        var failures: std.ArrayList(u8) = .empty;

        for (downloads.items[0..downloads.count]) |item| {
            counts[@intFromEnum(item.state)] += 1;

            if (item.state == .failed) {
                try failures.print(arena, "\n- {s}: {s}", .{ item.url, item.why });
            }
        }

        const pending = counts[@intFromEnum(State.waiting)] + counts[@intFromEnum(State.working)];

        return std.fmt.allocPrint(arena, "{d} files: {d} downloaded, {d} still on the way, " ++
            "{d} failed (into the media folder; `media sync` takes in what has arrived).{s}", .{
            downloads.count,
            counts[@intFromEnum(State.done)],
            pending,
            counts[@intFromEnum(State.failed)],
            failures.items,
        });
    }

    fn take(downloads: *Downloads) ?*Item {
        std.debug.assert(downloads.count <= files_max);

        downloads.mutex.lockUncancelable(downloads.io);
        defer downloads.mutex.unlock(downloads.io);

        for (downloads.items[0..downloads.count]) |*item| {
            if (item.state == .waiting) {
                item.state = .working;
                return item;
            }
        }

        return null;
    }

    fn settle(downloads: *Downloads, item: *Item, why: ?[]const u8) void {
        std.debug.assert(item.state == .working);

        downloads.mutex.lockUncancelable(downloads.io);
        defer downloads.mutex.unlock(downloads.io);

        item.state = if (why == null) .done else .failed;
        item.why = why orelse "";
    }

    /// One worker: takes the next waiting file until none waits, then ends.
    fn work(downloads: *Downloads) void {
        std.debug.assert(downloads.root.len > 0);

        var taken: u32 = 0;

        while (taken < files_max) : (taken += 1) {
            const item = downloads.take() orelse break;

            downloads.settle(item, fetch_into(downloads.io, downloads.root, item.url, item.path));
        }

        downloads.mutex.lockUncancelable(downloads.io);
        downloads.workers -= 1;
        downloads.mutex.unlock(downloads.io);
    }
};

/// Downloads `url` to `<root>/<path>`; why it could not, or null.
fn fetch_into(io: std.Io, root: []const u8, url: []const u8, path: []const u8) ?[]const u8 {
    std.debug.assert(url.len > 0);
    std.debug.assert(path.len > 0);

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const result = timed.fetch(io, arena, .{
        .url = url,
        .body_max = bytes_max,
    }, file_timeout_ms) catch |err| {
        return switch (err) {
            error.TimedOut => "not done within 2 minutes",
            error.TooBig => "larger than 32 MiB",
            else => "did not answer",
        };
    };

    if (result.status != .ok) {
        return "did not answer with a file";
    }

    const bytes = result.body;

    if (bytes.len == 0 or bytes.len > bytes_max) {
        return "empty, or larger than 32 MiB";
    }

    var dir = std.Io.Dir.cwd().openDir(io, root, .{}) catch return "the media folder is missing";
    defer dir.close(io);

    if (std.fs.path.dirname(path)) |folder| {
        dir.createDirPath(io, folder) catch return "could not make its folder";
    }

    dir.writeFile(io, .{
        .sub_path = path,
        .data = bytes,
    }) catch return "could not be written";

    return null;
}

/// An https or http address on a public host.
pub fn public_url(url: []const u8) bool {
    std.debug.assert(url.len <= std.math.maxInt(u32));

    const uri = std.Uri.parse(url) catch return false;
    const web = std.mem.eql(u8, uri.scheme, "https") or std.mem.eql(u8, uri.scheme, "http");
    const host = switch (uri.host orelse return false) {
        .raw, .percent_encoded => |text| text,
    };

    return web and url.len <= 2048 and http_operations.public_host(host);
}

/// `<folder>/<name>`: the address's file name, as a library key takes it (lowercase
/// letters, digits, `.-_`), numbered when it has none, so `media sync` keeps it in place.
fn path_of(
    allocator: std.mem.Allocator,
    folder: []const u8,
    url: []const u8,
    index: u32,
) ![]const u8 {
    std.debug.assert(folder.len > 0);
    std.debug.assert(index < files_max);

    const end = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    const host_start = (std.mem.indexOf(u8, url[0..end], "://") orelse 0) + 3;
    const path_start = std.mem.indexOfScalarPos(u8, url[0..end], host_start, '/') orelse end;
    // Only the path names the file: `https://a.pl/` has none.
    const base = std.fs.path.basename(url[path_start..end]);
    var name: std.ArrayList(u8) = .empty;
    defer name.deinit(allocator);

    for (base[0..@min(base.len, name_len_max)]) |char| {
        const lower = std.ascii.toLower(char);
        const kept = std.ascii.isAlphanumeric(lower) or lower == '.' or lower == '-' or
            lower == '_';

        try name.append(allocator, if (kept) lower else '-');
    }

    const named = name.items.len > 0 and name.items[0] != '.' and
        std.mem.indexOfScalar(u8, name.items, '.') != null;

    if (!named) {
        return std.fmt.allocPrint(allocator, "{s}/file-{d}", .{ folder, index });
    }

    // Numbered by its place in the queue: two files of one name never meet.
    return std.fmt.allocPrint(allocator, "{s}/{d}-{s}", .{ folder, index, name.items });
}

/// A folder name from a site's host: `www.wagmatik.pl` is `wagmatik-pl`.
pub fn folder_of_host(arena: std.mem.Allocator, host: []const u8) ![]const u8 {
    std.debug.assert(host.len > 0);

    const bare = if (std.mem.startsWith(u8, host, "www.")) host[4..] else host;
    const folder = try arena.dupe(u8, bare[0..@min(bare.len, 60)]);

    for (folder) |*char| {
        char.* = if (std.ascii.isAlphanumeric(char.*)) std.ascii.toLower(char.*) else '-';
    }

    return folder;
}

test "files get keys the library keeps in place" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "wagmatik-pl/3-hero_big.jpg",
        try path_of(arena, "wagmatik-pl", "https://wagmatik.pl/up/Hero_Big.jpg?v=2", 3),
    );
    const unnamed = try path_of(arena, "wagmatik-pl", "https://a.pl/", 4);

    try std.testing.expectEqualStrings("wagmatik-pl/file-4", unnamed);
    try std.testing.expectEqualStrings("wagmatik-pl", try folder_of_host(arena, "www.wagmatik.pl"));
    try std.testing.expect(public_url("https://wagmatik.pl/a.jpg"));
    try std.testing.expect(!public_url("http://127.0.0.1/a.jpg"));
    try std.testing.expect(!public_url("file:///etc/passwd"));
}
