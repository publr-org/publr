const std = @import("std");
const address = @import("app/address.zig");

pub const Resolved = address.Resolved;
pub const resolve = address.resolve;
pub const url = address.url;
pub const domain_of = address.domain_of;

pub const name_len_max: u32 = 32;
/// A DNS label.
pub const subdomain_len_max: u32 = 63;
pub const path_len_max: u32 = 128;
pub const segments_max: u32 = 8;
pub const tokens_max: u32 = 1024;
pub const roles_max: u32 = 16;
pub const host_len_max = address.host_len_max;

/// Where an app answers, on the project's one domain.
pub const Mount = union(enum) {
    /// Under a path: `/` for the root, `/newsletter` for everything below it.
    path: []const u8,
    /// A subdomain: `app` answers `app.example.com`.
    subdomain: []const u8,
};

/// A design token over the stylesheet's defaults: `color-accent`, `#2f5d54`.
pub const Token = struct { name: []const u8, value: []const u8 };

/// What `app.zon` declares.
pub const Config = struct {
    mount: Mount,
    tokens: []const Token = &.{},
    /// The roles a signed-in visitor needs to be signed in to this app; empty for any role.
    roles: []const []const u8 = &.{},
};

/// The paths that are core's on every host: the admin, the API, the sign-on and the toolbar.
pub const reserved_segments = [_][]const u8{ "admin", "api", "auth", "_publr" };

/// An app's folder name: `[a-z][a-z0-9_]*`, 1 to 32 characters.
pub fn valid_name(name: []const u8) bool {
    std.debug.assert(name_len_max > 0);

    if (name.len == 0 or name.len > name_len_max) {
        return false;
    }

    if (name[0] < 'a' or name[0] > 'z') {
        return false;
    }

    for (name) |char| {
        const lower = char >= 'a' and char <= 'z';
        const digit = char >= '0' and char <= '9';

        if (!lower and !digit and char != '_') {
            return false;
        }
    }

    std.debug.assert(name.len <= name_len_max);

    return true;
}

pub fn valid_mount(mount: Mount) bool {
    std.debug.assert(path_len_max > 1);
    std.debug.assert(subdomain_len_max > 0);

    return switch (mount) {
        .path => |path| valid_path(path),
        .subdomain => |label| valid_subdomain(label),
    };
}

/// `/`, or lower-case segments of `[a-z0-9_-]` under it, with no trailing slash and no
/// segment core keeps for itself.
fn valid_path(path: []const u8) bool {
    std.debug.assert(reserved_segments.len > 0);

    if (path.len == 0 or path.len > path_len_max or path[0] != '/') {
        return false;
    }

    if (path.len == 1) {
        return true;
    }

    var segments = std.mem.splitScalar(u8, path[1..], '/');
    var count: u32 = 0;

    while (segments.next()) |segment| : (count += 1) {
        if (count == segments_max or segment.len == 0 or !plain(segment)) {
            return false;
        }

        if (count == 0 and reserved(segment)) {
            return false;
        }
    }

    std.debug.assert(count > 0);

    return true;
}

fn valid_subdomain(label: []const u8) bool {
    std.debug.assert(subdomain_len_max == 63);

    if (label.len == 0 or label.len > subdomain_len_max) {
        return false;
    }

    if (label[0] == '-' or label[label.len - 1] == '-' or std.mem.eql(u8, label, "www")) {
        return false;
    }

    for (label) |char| {
        const lower = char >= 'a' and char <= 'z';
        const digit = char >= '0' and char <= '9';

        if (!lower and !digit and char != '-') {
            return false;
        }
    }

    return true;
}

fn plain(segment: []const u8) bool {
    std.debug.assert(segment.len > 0);

    for (segment) |char| {
        const lower = char >= 'a' and char <= 'z';
        const digit = char >= '0' and char <= '9';

        if (!lower and !digit and char != '-' and char != '_') {
            return false;
        }
    }

    return true;
}

fn reserved(segment: []const u8) bool {
    std.debug.assert(segment.len > 0);

    if (segment[0] == '_') {
        return true;
    }

    for (reserved_segments) |name| {
        if (std.mem.eql(u8, segment, name)) {
            return true;
        }
    }

    return false;
}

/// Whether two mounts would answer the same requests.
pub fn same_place(left: Mount, right: Mount) bool {
    std.debug.assert(valid_mount(left));
    std.debug.assert(valid_mount(right));

    return switch (left) {
        .path => |path| right == .path and std.mem.eql(u8, path, right.path),
        .subdomain => |label| right == .subdomain and std.mem.eql(u8, label, right.subdomain),
    };
}

/// What an app's own URLs start with on its host: `/newsletter` under a path, nothing at
/// the root or on a subdomain.
pub fn base_path(mount: Mount) []const u8 {
    std.debug.assert(valid_mount(mount));

    return switch (mount) {
        .path => |path| if (path.len == 1) "" else path,
        .subdomain => "",
    };
}

test "names are lower-case words" {
    try std.testing.expect(valid_name("www"));
    try std.testing.expect(valid_name("members_2"));

    for ([_][]const u8{ "", "Www", "2www", "w-w", "w.w", "a" ** 33 }) |bad| {
        try std.testing.expect(!valid_name(bad));
    }
}

test "mounts: the root, plain paths and plain subdomains; never core's own paths" {
    for ([_]Mount{
        .{ .path = "/" },
        .{ .path = "/newsletter" },
        .{ .path = "/docs/v2" },
        .{ .subdomain = "app" },
        .{ .subdomain = "my-app2" },
    }) |good| {
        try std.testing.expect(valid_mount(good));
    }

    for ([_]Mount{
        .{ .path = "" },
        .{ .path = "newsletter" },
        .{ .path = "/newsletter/" },
        .{ .path = "/News" },
        .{ .path = "/a//b" },
        .{ .path = "/admin" },
        .{ .path = "/api/v1" },
        .{ .path = "/_islands" },
        .{ .path = "/a/b/c/d/e/f/g/h/i" },
        .{ .subdomain = "" },
        .{ .subdomain = "-app" },
        .{ .subdomain = "a.b" },
        .{ .subdomain = "App" },
        .{ .subdomain = "www" },
    }) |bad| {
        try std.testing.expect(!valid_mount(bad));
    }
}

test "an app's own URLs start with its path, never with a subdomain's" {
    try std.testing.expectEqualStrings("", base_path(.{ .path = "/" }));
    try std.testing.expectEqualStrings("/newsletter", base_path(.{ .path = "/newsletter" }));
    try std.testing.expectEqualStrings("", base_path(.{ .subdomain = "app" }));
    try std.testing.expect(same_place(.{ .path = "/a" }, .{ .path = "/a" }));
    try std.testing.expect(!same_place(.{ .path = "/a" }, .{ .subdomain = "a" }));
}

test {
    std.testing.refAllDecls(address);
}
