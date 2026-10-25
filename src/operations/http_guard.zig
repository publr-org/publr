//! A request that goes only where it may: the host checked against the grant's domains and
//! the scheme, then every address it resolves to checked (in production none local or
//! private), and the connection made to a checked address, so a name that changes its
//! answer between the check and the call cannot slip through. Each redirect is a new hop
//! under the same checks.
const std = @import("std");
const outside = @import("../model/outside.zig");
const egress = @import("../model/egress.zig");

const Client = std.http.Client;
const HostName = std.Io.net.HostName;
const IpAddress = std.Io.net.IpAddress;

/// Redirects followed, at most.
pub const hops_max: u32 = 3;
const addresses_max: u32 = 32;

pub const Guard = struct {
    /// The grant's domains; null for core's own download: any host but this machine.
    domains: ?[]const []const u8,
    rule: outside.Rule,
};

pub const Error = error{ Refused, Unreachable, OutOfMemory };

/// Why the last check refused, for the log.
pub const Checked = struct {
    refusal: ?outside.Refusal = null,
};

/// The host of `uri` as written.
pub fn host_text(uri: std.Uri) []const u8 {
    const host = uri.host orelse return "";

    return switch (host) {
        .raw, .percent_encoded => |text| text,
    };
}

/// The path of `uri` as written, never its query.
pub fn path_text(uri: std.Uri) []const u8 {
    const text = switch (uri.path) {
        .raw, .percent_encoded => |path| path,
    };

    return if (text.len == 0) "/" else text;
}

/// What `uri` meets before any address is looked up, or null to go on.
pub fn refusal_of_name(guard: Guard, uri: std.Uri) ?outside.Refusal {
    const host = host_text(uri);

    std.debug.assert(guard.rule.own_hosts.len <= 16);

    if (host.len == 0) {
        return .not_listed;
    }

    const domains = guard.domains orelse {
        const web = std.mem.eql(u8, uri.scheme, "https") or std.mem.eql(u8, uri.scheme, "http");

        if (!web) {
            return .not_https;
        }

        return if (outside.this_machine(host)) .local else null;
    };

    return outside.refusal_of_name(guard.rule, domains, uri.scheme, host);
}

/// A connection to `uri`'s host, every address it resolves to allowed, made to one of them.
pub fn connect(
    client: *Client,
    guard: Guard,
    uri: std.Uri,
    checked: *Checked,
) Error!*Client.Connection {
    std.debug.assert(checked.refusal == null);

    if (refusal_of_name(guard, uri)) |refusal| {
        checked.refusal = refusal;

        return error.Refused;
    }

    const protocol = Client.Protocol.fromUri(uri) orelse return error.Unreachable;
    const port = uri.port orelse @as(u16, if (protocol == .tls) 443 else 80);
    var name_buffer: [HostName.max_len]u8 = undefined;
    const host = uri.getHost(&name_buffer) catch return error.Unreachable;

    switch (guard.rule.egress) {
        .direct => {},
        .off => {
            checked.refusal = .offline;

            return error.Refused;
        },
        .through => |through| return proxied(client, through, protocol, host, port, checked),
    }

    const pinned = try resolved(client.io, guard.rule, host, port, checked);

    if (protocol == .tls) {
        try certificates_loaded(client);
    }

    var address_buffer: [64]u8 = undefined;
    const target = if (pinned) |address| address_name(&address_buffer, address) else host;

    return client.connectTcpOptions(.{
        .host = target,
        .port = port,
        .protocol = protocol,
        .proxied_host = host,
        .proxied_port = port,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Unreachable,
    };
}

/// Through the host's egress proxy, which looks the name up and checks every address itself:
/// this server may have no way to. The connection's TLS still names `host`, so the
/// certificate checked is the site's, end to end.
fn proxied(
    client: *Client,
    through: egress.Through,
    protocol: Client.Protocol,
    host: HostName,
    port: u16,
    checked: *Checked,
) Error!*Client.Connection {
    std.debug.assert(through.host.len > 0);
    std.debug.assert(checked.refusal == null);

    const tls = protocol == .tls;

    if (port != @as(u16, if (tls) 443 else 80)) {
        checked.refusal = .not_web_port;

        return error.Refused;
    }

    if (tls) {
        try certificates_loaded(client);
    }

    const proxy = HostName.init(through.host) catch return error.Unreachable;

    return client.connectTcpOptions(.{
        .host = proxy,
        .port = egress.port_for(through, tls),
        .protocol = protocol,
        .proxied_host = host,
        .proxied_port = port,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Unreachable,
    };
}

/// Every address `host` resolves to, checked (in production, none the server's own either);
/// answers the one to connect to: the first IPv4 one, else the first IPv6 one, so the
/// connection goes where the check looked.
fn resolved(
    io: std.Io,
    rule: outside.Rule,
    host: HostName,
    port: u16,
    checked: *Checked,
) Error!?IpAddress {
    std.debug.assert(host.bytes.len > 0);
    std.debug.assert(addresses_max >= 16);

    var buffer: [addresses_max]IpAddress = undefined;
    const addresses = try looked_up(io, host, port, &buffer);

    if (addresses.len == 0) {
        return error.Unreachable;
    }

    var own_buffer: [addresses_max]IpAddress = undefined;
    const own = if (rule.production) own_of(io, rule, &own_buffer) else own_buffer[0..0];

    for (addresses) |address| {
        if (!outside.address_allowed(rule, address) or outside.among(own, address)) {
            checked.refusal = .local;

            return error.Refused;
        }
    }

    return pinned_of(addresses);
}

/// The addresses `host` resolves to, at most `buffer.len`.
fn looked_up(
    io: std.Io,
    host: HostName,
    port: u16,
    buffer: *[addresses_max]IpAddress,
) Error![]const IpAddress {
    std.debug.assert(host.bytes.len > 0);

    var results: [addresses_max]HostName.LookupResult = undefined;
    var queue: std.Io.Queue(HostName.LookupResult) = .init(&results);
    var found: u32 = 0;

    host.lookup(io, &queue, .{
        .port = port,
    }) catch return error.Unreachable;

    while (queue.getOne(io)) |result| {
        const address = switch (result) {
            .address => |address| address,
            .canonical_name => continue,
        };

        if (found < buffer.len) {
            buffer[found] = address;
            found += 1;
        }
    } else |err| switch (err) {
        error.Closed => {},
        error.Canceled => return error.Unreachable,
    }

    return buffer[0..found];
}

/// What the server's own hosts resolve to, looked up now (a name that cannot be looked up
/// adds nothing): a name pointing at this server by its public address is refused too.
fn own_of(io: std.Io, rule: outside.Rule, buffer: *[addresses_max]IpAddress) []const IpAddress {
    std.debug.assert(rule.own_hosts.len <= 16);

    var count: usize = 0;

    for (rule.own_hosts) |own| {
        if (outside.this_machine(own)) {
            continue;
        }

        const name = HostName.init(own) catch continue;
        var found: [addresses_max]IpAddress = undefined;
        const addresses = looked_up(io, name, 443, &found) catch continue;

        for (addresses) |address| {
            if (count < buffer.len) {
                buffer[count] = address;
                count += 1;
            }
        }
    }

    return buffer[0..count];
}

/// The address to connect to: the first IPv4 one, else the first IPv6 one with no scope
/// (one with a scope, only ever on a local network in development, goes by name).
fn pinned_of(addresses: []const IpAddress) ?IpAddress {
    std.debug.assert(addresses.len <= addresses_max);

    for (addresses) |address| {
        if (address == .ip4) {
            return address;
        }
    }

    for (addresses) |address| {
        if (address == .ip6 and address.ip6.interface.isNone()) {
            return address;
        }
    }

    return null;
}

/// `address` written as a host to connect to, its port left off. An IPv6 address is no
/// host name a check would accept, so it is carried as one as is: the lookup the connection
/// makes reads it back as that address, never asking a name server.
fn address_name(buffer: *[64]u8, address: IpAddress) HostName {
    std.debug.assert(buffer.len >= 46);

    const text = switch (address) {
        .ip4 => |ip4| std.fmt.bufPrint(buffer, "{d}.{d}.{d}.{d}", .{
            ip4.bytes[0],
            ip4.bytes[1],
            ip4.bytes[2],
            ip4.bytes[3],
        }) catch unreachable,
        .ip6 => |ip6| std.fmt.bufPrint(buffer, "{f}", .{std.Io.net.Ip6Address.Unresolved{
            .bytes = ip6.bytes,
            .interface_name = null,
        }}) catch unreachable,
    };

    return .{
        .bytes = text,
    };
}

/// The system's certificates loaded before the connection is made: `request` would load them
/// only when it connects itself.
fn certificates_loaded(client: *Client) Error!void {
    std.debug.assert(!Client.disable_tls);

    if (client.now != null) {
        return;
    }

    const now = std.Io.Clock.real.now(client.io);

    client.ca_bundle.rescan(client.allocator, client.io, now) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Unreachable,
    };
    client.now = now;
    std.debug.assert(client.now != null);
}

/// Where a redirect from `uri` to `location` leads, in `arena`; null when it cannot be read.
pub fn next(arena: std.mem.Allocator, uri: std.Uri, location: []const u8) ?std.Uri {
    std.debug.assert(location.len <= 64 << 10);

    const buffer = arena.alloc(u8, location.len + 4096) catch return null;
    var rest: []u8 = buffer;

    @memcpy(buffer[0..location.len], location);

    return uri.resolveInPlace(location.len, &rest) catch null;
}

test "a redirect leads where its location says, relative or whole" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const from = try std.Uri.parse("https://api.example.com/v1/prices?key=1");

    const whole = next(arena, from, "https://other.example.org/x").?;

    try std.testing.expectEqualStrings("other.example.org", host_text(whole));

    const relative = next(arena, from, "/v2/prices").?;

    try std.testing.expectEqualStrings("api.example.com", host_text(relative));
    try std.testing.expectEqualStrings("/v2/prices", path_text(relative));
}

test "a name is refused before any lookup when unlisted, plain http, or local in production" {
    const domains = [_][]const u8{ "api.example.com", "localhost" };
    const production: Guard = .{
        .domains = &domains,
        .rule = .{},
    };
    const development: Guard = .{
        .domains = &domains,
        .rule = .{
            .production = false,
        },
    };
    const elsewhere = try std.Uri.parse("https://other.example.org/x");
    const local = try std.Uri.parse("http://localhost:8080/x");

    const unlisted = outside.Refusal.not_listed;

    try std.testing.expectEqual(unlisted, refusal_of_name(production, elsewhere).?);
    try std.testing.expectEqual(outside.Refusal.local, refusal_of_name(production, local).?);
    try std.testing.expectEqual(null, refusal_of_name(development, local));
}

test "the connection goes to the checked address, IPv6 as well as IPv4" {
    var buffer: [64]u8 = undefined;
    const six = try IpAddress.parse("2606:4700::1", 443);

    try std.testing.expectEqualStrings("2606:4700::1", address_name(&buffer, six).bytes);

    const four = try IpAddress.parse("93.184.216.34", 443);

    try std.testing.expectEqualStrings("93.184.216.34", address_name(&buffer, four).bytes);

    const both = [_]IpAddress{ six, four };

    try std.testing.expect(pinned_of(&both).? == .ip4);
    try std.testing.expect(pinned_of(&.{six}).? == .ip6);

    // The pinned IPv6 text reads back as the same address, with no name server asked.
    const io = std.testing.io;
    var looked: [addresses_max]IpAddress = undefined;
    const back = try looked_up(io, address_name(&buffer, six), 443, &looked);

    try std.testing.expect(back.len >= 1);
    try std.testing.expect(outside.among(back[0..1], six));
}

test "in production a host resolving to one of the server's own hosts' addresses is refused" {
    const io = std.testing.io;
    const host = try HostName.init("203.0.113.9");
    var checked: Checked = .{};
    const production: outside.Rule = .{
        .own_hosts = &.{"203.0.113.9"},
    };

    try std.testing.expectError(error.Refused, resolved(io, production, host, 443, &checked));
    try std.testing.expectEqual(outside.Refusal.local, checked.refusal.?);

    var other: Checked = .{};
    const elsewhere: outside.Rule = .{
        .own_hosts = &.{"203.0.113.10"},
    };
    const pinned = try resolved(io, elsewhere, host, 443, &other);

    try std.testing.expect(pinned.? == .ip4);
    try std.testing.expectEqual(null, other.refusal);
}
