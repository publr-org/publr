//! How this server's outside calls leave, as its host says in `PUBLR_EGRESS`: straight out
//! (unset, a server of one's own), not at all (`off`: a host keeping the site offline), or
//! through the host's egress proxy (`<host>:<port>`). The proxy takes TLS on `port`, the
//! host named in the handshake, and plain http on `port + 1`, the host named in `Host`; it
//! decides which addresses may be reached, since a server behind one cannot look them up.
const std = @import("std");

pub const variable = "PUBLR_EGRESS";
pub const host_len_max: u32 = 253;

pub const Egress = union(enum) {
    direct,
    off,
    through: Through,
};

pub const Through = struct {
    host: []const u8,
    /// TLS; plain http one above it.
    port: u16,
};

/// `PUBLR_EGRESS`'s value as an egress: unset or empty is direct; anything unreadable is
/// off, so a host's mistake never lets a site out unchecked.
pub fn parse(text: ?[]const u8) Egress {
    const value = text orelse return .direct;

    std.debug.assert(host_len_max > 0);

    if (value.len == 0) {
        return .direct;
    }

    const colon = std.mem.lastIndexOfScalar(u8, value, ':') orelse return .off;
    const host = value[0..colon];
    const port = std.fmt.parseInt(u16, value[colon + 1 ..], 10) catch return .off;

    if (host.len == 0 or host.len > host_len_max or port == 0 or port == std.math.maxInt(u16)) {
        return .off;
    }

    return .{
        .through = .{
            .host = host,
            .port = port,
        },
    };
}

/// The proxy's port for a request: TLS on its own, plain http one above.
pub fn port_for(through: Through, tls: bool) u16 {
    std.debug.assert(through.port > 0);
    std.debug.assert(through.port < std.math.maxInt(u16));

    return if (tls) through.port else through.port + 1;
}

test "unset is direct, off is off, an address is the proxy, anything else is off" {
    try std.testing.expectEqual(Egress.direct, parse(null));
    try std.testing.expectEqual(Egress.direct, parse(""));
    try std.testing.expectEqual(Egress.off, parse("off"));
    try std.testing.expectEqual(Egress.off, parse("127.0.0.1"));
    try std.testing.expectEqual(Egress.off, parse("127.0.0.1:http"));
    try std.testing.expectEqual(Egress.off, parse(":3400"));

    const through = parse("127.0.0.1:3400").through;

    try std.testing.expectEqualStrings("127.0.0.1", through.host);
    try std.testing.expectEqual(@as(u16, 3400), port_for(through, true));
    try std.testing.expectEqual(@as(u16, 3401), port_for(through, false));
}
