//! Where a plugin's outside call may go: the domains on its `http.fetch` grant (exact, a
//! subdomain wildcard, or `*` for any public address) and, in production, never a local or
//! private address nor the server itself, whatever is listed.
const std = @import("std");

const IpAddress = std.Io.net.IpAddress;

/// How many domains one grant lists.
pub const domains_max: u32 = 32;
pub const domain_len_max: u32 = 253;

/// What decides the address rules: production refuses local and private addresses and the
/// server's own hosts; development lets plain http reach this machine when it is listed.
pub const Rule = struct {
    production: bool = true,
    /// The server's own host names (the site's, the admin's): never called in production.
    own_hosts: []const []const u8 = &.{},
    /// The public addresses on the machine's own network interfaces: never called in
    /// production either, whatever name leads there.
    own_addresses: []const IpAddress = &.{},
};

/// How many of the machine's own addresses a rule keeps.
pub const own_addresses_max: u32 = 32;

/// The rule for a server whose site answers at `site_origin`, its own hosts `own_hosts`:
/// production on a hosting service (`hosted`) or when the site is not served over plain
/// http (the switch a session cookie's `Secure` follows); a laptop's `serve` is development.
pub fn rule_of(hosted: bool, site_origin: []const u8, own_hosts: []const []const u8) Rule {
    std.debug.assert(own_hosts.len <= 16);
    std.debug.assert(site_origin.len <= 64 << 10);

    const plain = std.ascii.startsWithIgnoreCase(site_origin, "http://");

    return .{
        .production = hosted or !plain,
        .own_hosts = own_hosts,
    };
}

/// `example.com` from `https://example.com:8080/path`: the host alone.
pub fn host_of_origin(origin: []const u8) []const u8 {
    std.debug.assert(origin.len <= 64 << 10);

    const after_scheme = if (std.mem.indexOf(u8, origin, "://")) |at| origin[at + 3 ..] else origin;
    const end = std.mem.indexOfAny(u8, after_scheme, ":/") orelse after_scheme.len;

    return after_scheme[0..end];
}

pub const Refusal = enum {
    /// The host is not among the grant's domains.
    not_listed,
    /// Plain http to anywhere but this machine in development.
    not_https,
    /// A local or private address, or the server itself, in production.
    local,

    pub fn text(refusal: Refusal) []const u8 {
        std.debug.assert(@intFromEnum(refusal) <= 2);

        return switch (refusal) {
            .not_listed => "not a domain on its http.fetch grant",
            .not_https => "only https, or plain http to this machine in development",
            .local => "a local or private address, or this server: refused in production",
        };
    }
};

/// Whether `domain` is one a grant may list: `*`, `*.example.com`, or a host name.
pub fn valid_domain(domain: []const u8) bool {
    std.debug.assert(domain_len_max > 0);

    if (std.mem.eql(u8, domain, "*")) {
        return true;
    }

    if (std.mem.startsWith(u8, domain, "*.")) {
        const rest = domain[2..];

        return valid_name(rest) and std.mem.indexOfScalar(u8, rest, '.') != null;
    }

    return valid_name(domain);
}

fn valid_name(name: []const u8) bool {
    std.debug.assert(domain_len_max > 0);

    if (name.len == 0 or name.len > domain_len_max or name[0] == '.' or name[0] == '-') {
        return false;
    }

    if (name[name.len - 1] == '.' or std.mem.indexOf(u8, name, "..") != null) {
        return false;
    }

    for (name) |char| {
        const ok = (char >= 'a' and char <= 'z') or (char >= '0' and char <= '9') or
            char == '-' or char == '.';

        if (!ok) {
            return false;
        }
    }

    return true;
}

/// Whether `host` is among `domains`: equal to one, under a `*.` one (never the bare name),
/// or anywhere for `*` except this machine, which is listed by name when meant.
pub fn listed(domains: []const []const u8, host: []const u8) bool {
    std.debug.assert(domains.len <= domains_max * 4);
    std.debug.assert(host.len > 0);

    for (domains) |domain| {
        if (std.mem.eql(u8, domain, "*")) {
            if (!this_machine(host)) {
                return true;
            }

            continue;
        }

        if (std.mem.startsWith(u8, domain, "*.")) {
            const suffix = domain[1..];
            const under = host.len > suffix.len and
                std.ascii.endsWithIgnoreCase(host, suffix);

            if (under) {
                return true;
            }

            continue;
        }

        if (std.ascii.eqlIgnoreCase(domain, host)) {
            return true;
        }
    }

    return false;
}

/// A name for this machine itself: `localhost`, a name under it, `127.*`, `[::1]`.
pub fn this_machine(host: []const u8) bool {
    std.debug.assert(host.len <= 64 << 10);

    return std.ascii.eqlIgnoreCase(host, "localhost") or std.mem.startsWith(u8, host, "127.") or
        std.ascii.endsWithIgnoreCase(host, ".localhost") or std.mem.eql(u8, host, "[::1]") or
        std.mem.eql(u8, host, "::1");
}

/// What a call to `scheme://host` meets before its address is known, or null to go on.
pub fn refusal_of_name(
    rule: Rule,
    domains: []const []const u8,
    scheme: []const u8,
    host: []const u8,
) ?Refusal {
    std.debug.assert(host.len > 0);
    std.debug.assert(domains.len <= domains_max * 4);

    if (!listed(domains, host)) {
        return .not_listed;
    }

    const https = std.ascii.eqlIgnoreCase(scheme, "https");
    const local_http = std.ascii.eqlIgnoreCase(scheme, "http") and this_machine(host);

    if (!https and !(local_http and !rule.production)) {
        return if (local_http) .local else .not_https;
    }

    if (rule.production and (this_machine(host) or own_host(rule, host))) {
        return .local;
    }

    return null;
}

fn own_host(rule: Rule, host: []const u8) bool {
    std.debug.assert(host.len > 0);
    std.debug.assert(rule.own_hosts.len <= 16);

    for (rule.own_hosts) |own| {
        if (std.ascii.eqlIgnoreCase(own, host)) {
            return true;
        }
    }

    return false;
}

/// Whether `address` may be called: anything in development; in production only a public
/// address that is not the server's own.
pub fn address_allowed(rule: Rule, address: IpAddress) bool {
    std.debug.assert(rule.own_hosts.len <= 16);
    std.debug.assert(rule.own_addresses.len <= own_addresses_max);

    return !rule.production or (public(address) and !among(rule.own_addresses, address));
}

/// Whether `address` is one of `addresses`, ports aside (an IPv4 address and its IPv6
/// mapped form are the same).
pub fn among(addresses: []const IpAddress, address: IpAddress) bool {
    std.debug.assert(addresses.len <= own_addresses_max * 2);

    const wanted = std.Io.net.Ip6Address.fromAny(address).bytes;

    for (addresses) |candidate| {
        const bytes = std.Io.net.Ip6Address.fromAny(candidate).bytes;

        if (std.mem.eql(u8, &bytes, &wanted)) {
            return true;
        }
    }

    return false;
}

/// An address on the public internet: never loopback, private, link-local (the cloud
/// metadata address among them), shared (CGNAT), unique-local, unspecified or multicast.
pub fn public(address: IpAddress) bool {
    return switch (address) {
        .ip4 => |ip4| public_ip4(ip4.bytes),
        .ip6 => |ip6| public_ip6(ip6.bytes),
    };
}

fn public_ip4(bytes: [4]u8) bool {
    std.debug.assert(bytes.len == 4);

    const first = bytes[0];
    const second = bytes[1];
    const local = first == 0 or first == 10 or first == 127 or first >= 224 or
        (first == 169 and second == 254) or (first == 172 and second >= 16 and second <= 31) or
        (first == 192 and second == 168) or (first == 100 and second >= 64 and second <= 127);

    return !local;
}

fn public_ip6(bytes: [16]u8) bool {
    std.debug.assert(bytes.len == 16);

    const mapped_prefix = [_]u8{0} ** 10 ++ [_]u8{ 0xff, 0xff };

    if (std.mem.eql(u8, bytes[0..12], &mapped_prefix)) {
        return public_ip4(bytes[12..16].*);
    }

    const zero_prefix = std.mem.allEqual(u8, bytes[0..15], 0);

    // `::` and `::1`, unique-local fc00::/7, link-local fe80::/10, multicast ff00::/8.
    if (zero_prefix and bytes[15] <= 1) {
        return false;
    }

    const unique_local = bytes[0] & 0xfe == 0xfc;
    const link_local = bytes[0] == 0xfe and bytes[1] & 0xc0 == 0x80;

    return !(unique_local or link_local or bytes[0] == 0xff);
}

test "a domain is exact, a subdomain wildcard or a star; subdomains are never implied" {
    const domains = [_][]const u8{ "api.supplier.com", "*.cdn.example.com" };

    try std.testing.expect(listed(&domains, "api.supplier.com"));
    try std.testing.expect(listed(&domains, "API.Supplier.com"));
    try std.testing.expect(!listed(&domains, "eu.api.supplier.com"));
    try std.testing.expect(!listed(&domains, "supplier.com"));
    try std.testing.expect(listed(&domains, "img.cdn.example.com"));
    try std.testing.expect(listed(&domains, "a.b.cdn.example.com"));
    try std.testing.expect(!listed(&domains, "cdn.example.com"));
    try std.testing.expect(!listed(&domains, "evilcdn.example.com"));

    const star = [_][]const u8{"*"};

    try std.testing.expect(listed(&star, "anything.example.org"));
    try std.testing.expect(!listed(&star, "localhost"));
    try std.testing.expect(!listed(&star, "127.0.0.1"));
    try std.testing.expect(!listed(&.{}, "api.supplier.com"));
}

test "only `*`, `*.name.tld` and plain lower-case host names are valid" {
    try std.testing.expect(valid_domain("*"));
    try std.testing.expect(valid_domain("*.example.com"));
    try std.testing.expect(valid_domain("api.example.com"));
    try std.testing.expect(valid_domain("localhost"));
    try std.testing.expect(!valid_domain("*.com"));
    try std.testing.expect(!valid_domain("*example.com"));
    try std.testing.expect(!valid_domain("api.*.com"));
    try std.testing.expect(!valid_domain("https://example.com"));
    try std.testing.expect(!valid_domain("example.com/path"));
    try std.testing.expect(!valid_domain("Example.com"));
    try std.testing.expect(!valid_domain(""));
    try std.testing.expect(!valid_domain(".example.com"));
    try std.testing.expect(!valid_domain("a..b"));
}

test "production refuses this machine and the server's own hosts; development lets http in" {
    const production: Rule = .{
        .own_hosts = &.{"shop.example.com"},
    };
    const development: Rule = .{
        .production = false,
    };
    const local = [_][]const u8{ "localhost", "shop.example.com", "api.example.com" };

    const refused_here = Refusal.local;

    try std.testing.expectEqual(null, refusal_of_name(development, &local, "http", "localhost"));
    try std.testing.expectEqual(
        refused_here,
        refusal_of_name(production, &local, "http", "localhost"),
    );
    try std.testing.expectEqual(
        refused_here,
        refusal_of_name(production, &local, "https", "localhost"),
    );
    try std.testing.expectEqual(
        Refusal.local,
        refusal_of_name(production, &local, "https", "shop.example.com"),
    );
    try std.testing.expectEqual(
        null,
        refusal_of_name(production, &local, "https", "api.example.com"),
    );
    try std.testing.expectEqual(
        Refusal.not_https,
        refusal_of_name(development, &local, "http", "api.example.com"),
    );
    try std.testing.expectEqual(
        Refusal.not_listed,
        refusal_of_name(development, &local, "https", "other.example.com"),
    );
}

test "a hosted or https site is production; a plain http one is development" {
    try std.testing.expect(rule_of(true, "http://shop.publr.localhost:8095", &.{}).production);
    try std.testing.expect(rule_of(false, "https://shop.example.com", &.{}).production);
    try std.testing.expect(rule_of(false, "", &.{}).production);
    try std.testing.expect(!rule_of(false, "http://127.0.0.1:8080", &.{}).production);
    const admin = host_of_origin("http://admin.localhost:8080");

    try std.testing.expectEqualStrings("admin.localhost", admin);
    try std.testing.expectEqualStrings("example.com", host_of_origin("https://example.com/a"));
}

test "private, loopback, link-local and metadata addresses are not public" {
    const refused = [_][]const u8{
        "127.0.0.1",       "10.1.2.3",   "172.16.0.1",      "172.31.255.255", "192.168.1.1",
        "169.254.169.254", "100.64.0.1", "0.0.0.0",         "::1",            "::",
        "fd00::1",         "fe80::1",    "::ffff:10.0.0.1", "ff02::1",        "224.0.0.1",
    };
    const allowed = [_][]const u8{ "93.184.216.34", "172.32.0.1", "100.128.0.1", "2606:4700::1" };
    const development: Rule = .{
        .production = false,
    };

    for (refused) |text| {
        const address = try IpAddress.parse(text, 443);

        try std.testing.expect(!public(address));
        try std.testing.expect(!address_allowed(.{}, address));
        try std.testing.expect(address_allowed(development, address));
    }

    for (allowed) |text| {
        try std.testing.expect(public(try IpAddress.parse(text, 443)));
    }
}

test "the server's own public addresses are refused in production, whatever the port" {
    const own = [_]IpAddress{
        try IpAddress.parse("203.0.113.9", 0),
        try IpAddress.parse("2001:db8::9", 0),
    };
    const production: Rule = .{
        .own_addresses = &own,
    };
    const development: Rule = .{
        .production = false,
        .own_addresses = &own,
    };

    try std.testing.expect(!address_allowed(production, try IpAddress.parse("203.0.113.9", 443)));
    try std.testing.expect(
        !address_allowed(production, try IpAddress.parse("::ffff:203.0.113.9", 443)),
    );
    try std.testing.expect(!address_allowed(production, try IpAddress.parse("2001:db8::9", 443)));
    try std.testing.expect(address_allowed(production, try IpAddress.parse("203.0.113.10", 443)));
    try std.testing.expect(address_allowed(development, try IpAddress.parse("203.0.113.9", 443)));
}
