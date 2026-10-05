const std = @import("std");
const app = @import("../app.zig");

const Mount = app.Mount;
const base_path = app.base_path;
const valid_mount = app.valid_mount;

pub const host_len_max: u32 = 255;

/// The request's app, and the path inside it (`/` and on).
pub const Resolved = struct { index: u32, path: []const u8 };

/// The app a request is for: a subdomain of `domain` goes to the app mounted there;
/// anything else to the path mount with the longest prefix. Null when nothing answers.
pub fn resolve(
    mounts: []const Mount,
    domain: []const u8,
    host: []const u8,
    path: []const u8,
) ?Resolved {
    std.debug.assert(path.len > 0);
    std.debug.assert(path[0] == '/');

    if (subdomain_of(host, domain)) |label| {
        for (mounts, 0..) |mount, index| {
            if (mount == .subdomain and std.ascii.eqlIgnoreCase(mount.subdomain, label)) {
                return .{ .index = @intCast(index), .path = path };
            }
        }
    }

    var best: ?Resolved = null;
    var best_len: u32 = 0;

    for (mounts, 0..) |mount, index| {
        if (mount != .path) {
            continue;
        }

        const inside = within(mount.path, path) orelse continue;
        const length: u32 = @intCast(mount.path.len);

        if (best == null or length > best_len) {
            best = .{ .index = @intCast(index), .path = inside };
            best_len = length;
        }
    }

    if (best) |found| {
        std.debug.assert(found.path.len > 0);
        std.debug.assert(found.path[0] == '/');
    }

    return best;
}

/// `path` as seen from under `prefix`, or null when it is not under it.
fn within(prefix: []const u8, path: []const u8) ?[]const u8 {
    std.debug.assert(prefix.len > 0);
    std.debug.assert(path[0] == '/');

    if (prefix.len == 1) {
        return path;
    }

    if (!std.mem.startsWith(u8, path, prefix)) {
        return null;
    }

    if (path.len == prefix.len) {
        return "/";
    }

    if (path[prefix.len] != '/') {
        return null;
    }

    return path[prefix.len..];
}

/// The first label of `host` when the rest is `domain` (ports ignored, any case).
fn subdomain_of(host: []const u8, domain: []const u8) ?[]const u8 {
    std.debug.assert(host.len <= 64 << 10);

    if (domain.len == 0 or host.len > host_len_max) {
        return null;
    }

    const bare = without_port(host);

    if (bare.len <= domain.len + 1) {
        return null;
    }

    const cut = bare.len - domain.len;

    if (bare[cut - 1] != '.' or !std.ascii.eqlIgnoreCase(bare[cut..], without_port(domain))) {
        return null;
    }

    const label = bare[0 .. cut - 1];

    if (std.mem.indexOfScalar(u8, label, '.') != null) {
        return null;
    }

    return label;
}

fn without_port(host: []const u8) []const u8 {
    std.debug.assert(host.len <= host_len_max);

    const colon = std.mem.lastIndexOfScalar(u8, host, ':') orelse return host;

    if (std.mem.indexOfScalar(u8, host[colon..], ']') != null) {
        return host;
    }

    return host[0..colon];
}

/// Where an app answers, from the project's address: under it for a path mount, before its
/// host for a subdomain (`https://example.com` and `app` are `https://app.example.com`).
/// Null when `base_url` is not `scheme://host...` or the result would not fit `buffer`.
pub fn url(buffer: []u8, base_url: []const u8, mount: Mount) ?[]const u8 {
    std.debug.assert(buffer.len > 0);
    std.debug.assert(valid_mount(mount));

    const scheme_end = std.mem.indexOf(u8, base_url, "://") orelse return null;
    const host_at = scheme_end + 3;

    if (host_at >= base_url.len) {
        return null;
    }

    const written = switch (mount) {
        .path => std.fmt.bufPrint(buffer, "{s}{s}", .{ base_url, base_path(mount) }),
        .subdomain => |label| std.fmt.bufPrint(buffer, "{s}{s}.{s}", .{
            base_url[0..host_at],
            label,
            base_url[host_at..],
        }),
    };

    return written catch null;
}

/// The host of the project's address, without its port: what subdomains hang from.
pub fn domain_of(base_url: []const u8) []const u8 {
    std.debug.assert(base_url.len <= 64 << 10);

    const scheme_end = std.mem.indexOf(u8, base_url, "://") orelse return "";
    const rest = base_url[scheme_end + 3 ..];
    const host = rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];

    if (host.len > host_len_max) {
        return "";
    }

    return without_port(host);
}

/// The path of the project's public address, which it is served under: `/environments/dev` of
/// `https://ada.publr.app/environments/dev`; empty at the root.
pub fn path_of(address: []const u8) []const u8 {
    const scheme = std.mem.indexOf(u8, address, "://") orelse return "";
    const rest = address[scheme + 3 ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return "";
    const path = std.mem.trimEnd(u8, rest[slash..], "/");

    std.debug.assert(path.len == 0 or path[0] == '/');

    return path;
}

test "the base is the path of the public address" {
    const dev = "/environments/dev";

    try std.testing.expectEqualStrings(dev, path_of("https://ada.publr.app/environments/dev"));
    try std.testing.expectEqualStrings(dev, path_of("https://ada.publr.app/environments/dev/"));
    try std.testing.expectEqualStrings("", path_of("https://ada.publr.app"));
    try std.testing.expectEqualStrings("", path_of("https://ada.publr.app/"));
    try std.testing.expectEqualStrings("", path_of("http://127.0.0.1:8080"));
}

/// Attributes whose value is an address the browser follows or loads.
pub fn url_attribute(name: []const u8) bool {
    std.debug.assert(name.len > 0);

    const names = [_][]const u8{ "href", "src", "action", "formaction", "poster" };

    for (names) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) {
            return true;
        }
    }

    return false;
}

/// Whether a root path lacks the base the project is served under: never another host
/// (`//…`), a full address, a fragment, or a path already at or under it. The same rule as
/// the admin's renders (`rt.needs_base`) and the browser's (`Publr.url`).
pub fn needs_base(base: []const u8, value: []const u8) bool {
    std.debug.assert(base.len == 0 or base[0] == '/');

    if (base.len == 0 or value.len == 0 or value[0] != '/') {
        return false;
    }

    if (value.len > 1 and value[1] == '/') {
        return false;
    }

    if (!std.mem.startsWith(u8, value, base)) {
        return true;
    }

    const rest = value[base.len..];

    return !(rest.len == 0 or rest[0] == '/' or rest[0] == '?' or rest[0] == '#');
}

test "a root path is written under the base, once" {
    const base = "/environments/dev";

    try std.testing.expect(needs_base(base, "/admin"));
    try std.testing.expect(needs_base(base, "/environments/devx"));
    try std.testing.expect(!needs_base(base, "/environments/dev/admin"));
    try std.testing.expect(!needs_base(base, "/environments/dev?x=1"));
    try std.testing.expect(!needs_base(base, "//cdn.example/a.js"));
    try std.testing.expect(!needs_base(base, "https://example.com/"));
    try std.testing.expect(!needs_base(base, "#top"));
    try std.testing.expect(!needs_base("", "/admin"));
    try std.testing.expect(url_attribute("HREF") and !url_attribute("data-href"));
}

/// A path the browser shows, without the base the project is served under:
/// `/environments/dev/about` is `/about`. Anything outside the base as it is.
pub fn without_base(base: []const u8, path: []const u8) []const u8 {
    std.debug.assert(base.len == 0 or base[0] == '/');

    if (base.len == 0 or !std.mem.startsWith(u8, path, base)) {
        return path;
    }

    const rest = path[base.len..];

    if (rest.len == 0) {
        return "/";
    }

    return if (rest[0] == '/') rest else path;
}

test "a path the browser shows loses the base, and only the base" {
    const base = "/environments/dev";

    try std.testing.expectEqualStrings("/about", without_base(base, "/environments/dev/about"));
    try std.testing.expectEqualStrings("/", without_base(base, "/environments/dev"));
    const other = "/environments/devx";

    try std.testing.expectEqualStrings(other, without_base(base, other));
    try std.testing.expectEqualStrings("/about", without_base("", "/about"));
}

test "resolve: the subdomain first, then the longest path, the path seen from inside" {
    const mounts = [_]Mount{
        .{ .path = "/" },
        .{ .path = "/newsletter" },
        .{ .subdomain = "app" },
    };
    const domain = "example.com";

    const root = resolve(&mounts, domain, "example.com", "/about").?;
    try std.testing.expectEqual(@as(u32, 0), root.index);
    try std.testing.expectEqualStrings("/about", root.path);

    const letter = resolve(&mounts, domain, "example.com:8080", "/newsletter/issues").?;
    try std.testing.expectEqual(@as(u32, 1), letter.index);
    try std.testing.expectEqualStrings("/issues", letter.path);

    const bare = resolve(&mounts, domain, "example.com", "/newsletter").?;
    try std.testing.expectEqualStrings("/", bare.path);

    const near = resolve(&mounts, domain, "example.com", "/newsletters").?;
    try std.testing.expectEqual(@as(u32, 0), near.index);

    const sub = resolve(&mounts, domain, "APP.example.com:8080", "/newsletter").?;
    try std.testing.expectEqual(@as(u32, 2), sub.index);
    try std.testing.expectEqualStrings("/newsletter", sub.path);

    // Another subdomain, or no domain known, is the domain's own paths.
    for ([_][2][]const u8{
        .{ domain, "www.example.com" },
        .{ "", "app.example.com" },
        .{ domain, "a.app.example.com" },
    }) |pair| {
        try std.testing.expectEqual(@as(u32, 0), resolve(&mounts, pair[0], pair[1], "/").?.index);
    }

    const nothing_at_root = [_]Mount{.{ .path = "/newsletter" }};
    try std.testing.expect(resolve(&nothing_at_root, domain, "example.com", "/") == null);
    try std.testing.expect(resolve(&.{}, domain, "example.com", "/") == null);
}

test "an app's address: under the project's for a path, before its host for a subdomain" {
    var buffer: [128]u8 = undefined;

    const base = "https://example.com";
    try std.testing.expectEqualStrings(base, url(&buffer, base, .{ .path = "/" }).?);
    const letter = url(&buffer, base, .{ .path = "/newsletter" }).?;
    try std.testing.expectEqualStrings("https://example.com/newsletter", letter);
    const sub = url(&buffer, "http://localhost:8080", .{ .subdomain = "app" }).?;
    try std.testing.expectEqualStrings("http://app.localhost:8080", sub);
    try std.testing.expect(url(&buffer, "example.com", .{ .path = "/" }) == null);
    try std.testing.expect(url(buffer[0..4], base, .{ .path = "/" }) == null);

    try std.testing.expectEqualStrings("example.com", domain_of("https://example.com:8443/x"));
    try std.testing.expectEqualStrings("localhost", domain_of("http://localhost:8080"));
    try std.testing.expectEqualStrings("", domain_of("nothing"));
}
