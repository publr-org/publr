const std = @import("std");
const address = @import("address.zig");

pub const entries_max: u32 = 64;
pub const url_len_max: u32 = 512;

/// One app given an address of its own by whoever runs the site: on the site whose public
/// address is `site` (its `--url`), app `app` answers at `url`. A copy of the site elsewhere
/// (an environment, a clone) has another `site`, so it never claims the entry.
pub const Entry = struct {
    site: []const u8,
    app: []const u8,
    url: []const u8,
};

pub const Error = error{ InvalidAddresses, OutOfMemory };

/// The entries `addresses.zon` lists: `.{ .{ .site = …, .app = …, .url = … }, … }`.
pub fn parse(arena: std.mem.Allocator, text: [:0]const u8) Error![]const Entry {
    std.debug.assert(text.len <= 1 << 20);

    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const entries = std.zon.parse.fromSlice([]const Entry, .{
        .gpa = arena,
        .arena = arena,
        .source = text,
        .diagnostics = &diagnostics,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidAddresses,
    };

    if (entries.len > entries_max) {
        return error.InvalidAddresses;
    }

    for (entries) |entry| {
        if (!valid_url(entry.url) or !valid_url(entry.site) or entry.app.len == 0) {
            return error.InvalidAddresses;
        }
    }

    std.debug.assert(entries.len <= entries_max);

    return entries;
}

/// An address an app can answer at: `http(s)://host`, a path allowed, nothing after it.
pub fn valid_url(url: []const u8) bool {
    std.debug.assert(url_len_max > 0);

    if (url.len == 0 or url.len > url_len_max) {
        return false;
    }

    if (std.mem.indexOfAny(u8, url, " \t\r\n?#") != null) {
        return false;
    }

    const http = std.mem.startsWith(u8, url, "http://");
    const https = std.mem.startsWith(u8, url, "https://");

    if (!http and !https) {
        return false;
    }

    const host = address.host_of(url);

    return host.len > 0 and host.len <= address.host_len_max and host[0] != ':';
}

/// The entries of the site at `base_url`, in `kept`; the rest belong to its copies.
pub fn of_site(entries: []const Entry, base_url: []const u8, kept: *[entries_max]Entry) []Entry {
    std.debug.assert(entries.len <= entries_max);
    std.debug.assert(base_url.len > 0);

    var len: u32 = 0;

    for (entries) |entry| {
        if (!same_address(entry.site, base_url)) {
            continue;
        }

        kept[len] = entry;
        len += 1;
    }

    return kept[0..len];
}

/// What is wrong with a site's entries: an app given two addresses, or two apps one host.
/// Null when nothing is.
pub fn problem(entries: []const Entry) ?[]const u8 {
    std.debug.assert(entries.len <= entries_max);

    for (entries, 0..) |entry, index| {
        for (entries[index + 1 ..]) |other| {
            if (std.mem.eql(u8, entry.app, other.app)) {
                return "an app is given two addresses";
            }

            if (std.ascii.eqlIgnoreCase(address.host_of(entry.url), address.host_of(other.url))) {
                return "two apps are given the same host";
            }
        }
    }

    return null;
}

/// The address the site's entries give `app`, without a trailing slash; null for none.
pub fn url_of(entries: []const Entry, app: []const u8) ?[]const u8 {
    std.debug.assert(entries.len <= entries_max);
    std.debug.assert(app.len > 0);

    for (entries) |entry| {
        if (std.mem.eql(u8, entry.app, app)) {
            return std.mem.trimEnd(u8, entry.url, "/");
        }
    }

    return null;
}

/// `path` as seen inside an app at `url`, when `host` is its host and `path` is under it.
pub fn inside(url: []const u8, host: []const u8, path: []const u8) ?[]const u8 {
    std.debug.assert(path.len > 0);
    std.debug.assert(path[0] == '/');

    if (!std.ascii.eqlIgnoreCase(address.host_of(url), host)) {
        return null;
    }

    const prefix = address.path_of(url);

    if (prefix.len == 0) {
        return path;
    }

    if (!std.mem.startsWith(u8, path, prefix)) {
        return null;
    }

    if (path.len == prefix.len) {
        return "/";
    }

    return if (path[prefix.len] == '/') path[prefix.len..] else null;
}

fn same_address(left: []const u8, right: []const u8) bool {
    std.debug.assert(left.len > 0);
    std.debug.assert(right.len > 0);

    const left_bare = std.mem.trimEnd(u8, left, "/");
    const right_bare = std.mem.trimEnd(u8, right, "/");

    return std.ascii.eqlIgnoreCase(left_bare, right_bare);
}

test "addresses are read from their file, and a broken one is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const entries = try parse(arena,
        \\.{
        \\    .{
        \\        .site = "https://kiosk.publr.app",
        \\        .app = "pos",
        \\        .url = "https://pos.mykiosk.com",
        \\    },
        \\}
    );

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("pos", entries[0].app);
    try std.testing.expectError(error.InvalidAddresses, parse(arena, ".{ .{ .app = 1 } }"));
    try std.testing.expectError(error.InvalidAddresses, parse(arena,
        \\.{ .{ .site = "https://a.app", .app = "pos", .url = "pos.mykiosk.com" } }
    ));
}

test "only the site's own entries count; a copy's are left alone" {
    const entries = [_]Entry{
        .{
            .site = "https://kiosk.publr.app",
            .app = "pos",
            .url = "https://pos.mykiosk.com",
        },
        .{
            .site = "https://kiosk--staging.publr.app",
            .app = "pos",
            .url = "https://s.mykiosk.com",
        },
    };
    var kept: [entries_max]Entry = undefined;
    const own = of_site(&entries, "https://kiosk.publr.app/", &kept);

    try std.testing.expectEqual(@as(usize, 1), own.len);
    try std.testing.expectEqualStrings("https://pos.mykiosk.com", url_of(own, "pos").?);
    try std.testing.expect(url_of(own, "kitchen") == null);
    try std.testing.expect(problem(own) == null);
}

test "an app twice, or a host twice, is a problem" {
    const twice = [_]Entry{
        .{
            .site = "https://a.app",
            .app = "pos",
            .url = "https://pos.example.com",
        },
        .{
            .site = "https://a.app",
            .app = "pos",
            .url = "https://till.example.com",
        },
    };
    const shared = [_]Entry{
        .{
            .site = "https://a.app",
            .app = "pos",
            .url = "https://shop.example.com",
        },
        .{
            .site = "https://a.app",
            .app = "till",
            .url = "https://SHOP.example.com/till",
        },
    };

    try std.testing.expect(problem(&twice) != null);
    try std.testing.expect(problem(&shared) != null);
}

test "a request is inside an app's address on its host, under its path" {
    const url = "https://example.com/pos";

    try std.testing.expectEqualStrings("/", inside(url, "example.com", "/pos").?);
    try std.testing.expectEqualStrings("/menu", inside(url, "example.com", "/pos/menu").?);
    try std.testing.expect(inside(url, "example.com", "/posters") == null);
    try std.testing.expect(inside(url, "other.com", "/pos") == null);
    const upper = inside("https://pos.example.com", "POS.example.com", "/a").?;

    try std.testing.expectEqualStrings("/a", upper);
}
