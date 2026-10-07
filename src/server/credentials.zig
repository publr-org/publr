//! The devices this machine signed in as: one token per Publr address, in
//! `~/.publr/credentials` (or `$PUBLR_CREDENTIALS`), readable by its user only.
const std = @import("std");

pub const file_bytes_max: u32 = 1 << 20;
pub const sites_max: u32 = 256;
pub const address_len_max: u32 = 512;

pub const Site = struct {
    address: []const u8,
    token: []const u8,
    email: []const u8 = "",
    scope: []const u8 = "",
};

const File = struct { sites: []const Site = &.{} };

/// An address as the user typed it, made whole: a scheme (`https://`, or `http://` for this
/// machine) and no trailing slash. Null when it cannot be one.
pub fn normalize(arena: std.mem.Allocator, text: []const u8) !?[]const u8 {
    std.debug.assert(address_len_max > 0);

    const trimmed = std.mem.trimEnd(u8, std.mem.trim(u8, text, " "), "/");

    if (trimmed.len == 0 or trimmed.len > address_len_max) {
        return null;
    }

    const schemed = std.mem.startsWith(u8, trimmed, "https://") or
        std.mem.startsWith(u8, trimmed, "http://");

    if (schemed) {
        return try arena.dupe(u8, trimmed);
    }

    const host_end = std.mem.indexOfAny(u8, trimmed, ":/") orelse trimmed.len;
    const scheme = if (on_this_machine(trimmed[0..host_end])) "http://" else "https://";

    return try std.fmt.allocPrint(arena, "{s}{s}", .{ scheme, trimmed });
}

/// A name that is this machine: `localhost`, `*.localhost`, `*.local` (a name in
/// `/etc/hosts`, as `publr.local`), a loopback address. A Publr there is `publr serve`,
/// which speaks plain http.
pub fn on_this_machine(host: []const u8) bool {
    std.debug.assert(host.len <= address_len_max);

    const ends = std.mem.endsWith;

    return std.mem.eql(u8, host, "localhost") or ends(u8, host, ".localhost") or
        ends(u8, host, ".local") or std.mem.startsWith(u8, host, "127.") or
        std.mem.eql(u8, host, "[::1]");
}

pub fn path_of(init: std.process.Init) !?[]const u8 {
    const arena = init.arena.allocator();
    const own = init.environ_map.get("PUBLR_CREDENTIALS") orelse "";

    if (own.len > 0) {
        return own;
    }

    const home = init.environ_map.get("HOME") orelse return null;

    std.debug.assert(home.len > 0);

    return try std.fs.path.join(arena, &.{ home, ".publr", "credentials" });
}

pub fn load(init: std.process.Init) ![]const Site {
    const arena = init.arena.allocator();
    const path = try path_of(init) orelse return &.{};
    const limit: std.Io.Limit = .limited(file_bytes_max);
    const text = std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, limit) catch |err| {
        return switch (err) {
            error.FileNotFound => &.{},
            else => err,
        };
    };
    const parsed = try std.json.parseFromSliceLeaky(File, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });

    std.debug.assert(parsed.sites.len <= sites_max);

    return parsed.sites;
}

/// The device kept for `address`; with no address, the only one kept, if there is one.
pub fn find(init: std.process.Init, address: ?[]const u8) !?Site {
    const sites = try load(init);

    std.debug.assert(sites.len <= sites_max);

    const wanted = if (address) |text|
        try normalize(init.arena.allocator(), text) orelse return null
    else
        return if (sites.len == 1) sites[0] else null;

    for (sites) |site| {
        if (std.mem.eql(u8, site.address, wanted)) {
            return site;
        }
    }

    return null;
}

/// Keeps `site`, replacing what was kept for its address.
pub fn put(init: std.process.Init, site: Site) !void {
    std.debug.assert(site.address.len > 0);
    std.debug.assert(site.token.len > 0);

    const arena = init.arena.allocator();
    const sites = try load(init);
    var kept: std.ArrayList(Site) = .empty;

    for (sites) |existing| {
        if (!std.mem.eql(u8, existing.address, site.address)) {
            try kept.append(arena, existing);
        }
    }

    if (kept.items.len == sites_max) {
        return error.TooManySites;
    }

    try kept.append(arena, site);
    try save(init, kept.items);
}

/// Forgets what was kept for `address`. False when nothing was.
pub fn remove(init: std.process.Init, address: []const u8) !bool {
    std.debug.assert(address.len > 0);

    const arena = init.arena.allocator();
    const sites = try load(init);
    var kept: std.ArrayList(Site) = .empty;

    for (sites) |existing| {
        if (!std.mem.eql(u8, existing.address, address)) {
            try kept.append(arena, existing);
        }
    }

    if (kept.items.len == sites.len) {
        return false;
    }

    try save(init, kept.items);

    return true;
}

fn save(init: std.process.Init, sites: []const Site) !void {
    std.debug.assert(sites.len <= sites_max);

    const arena = init.arena.allocator();
    const path = try path_of(init) orelse return error.NoHome;
    const text = try std.json.Stringify.valueAlloc(arena, File{ .sites = sites }, .{
        .whitespace = .indent_2,
    });
    const cwd = std.Io.Dir.cwd();

    if (std.fs.path.dirname(path)) |dir| {
        try cwd.createDirPath(init.io, dir);
    }

    var file = try cwd.createFile(init.io, path, .{ .permissions = .fromMode(0o600) });
    defer file.close(init.io);

    try file.writeStreamingAll(init.io, text);
}

test "addresses: a scheme, no trailing slash, http only for this machine" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "https://example.com",
        (try normalize(arena, "example.com/")).?,
    );
    try std.testing.expectEqualStrings(
        "http://localhost:8080",
        (try normalize(arena, "localhost:8080")).?,
    );
    try std.testing.expectEqualStrings(
        "http://ada.publr.localhost:8095",
        (try normalize(arena, "ada.publr.localhost:8095")).?,
    );
    try std.testing.expectEqualStrings(
        "http://h:1/base",
        (try normalize(arena, "http://h:1/base/")).?,
    );
    try std.testing.expectEqualStrings(
        "http://publr.local:8080",
        (try normalize(arena, "publr.local:8080")).?,
    );
    try std.testing.expectEqualStrings(
        "https://shop.example",
        (try normalize(arena, "shop.example")).?,
    );
    try std.testing.expect(try normalize(arena, " / ") == null);
}
