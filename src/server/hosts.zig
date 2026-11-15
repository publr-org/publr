//! Whether a host is this machine: which `Host` headers name it, and which may carry tokens
//! over plain http under the OAuth rules.
const std = @import("std");

pub const address_len_max: u32 = 512;

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

/// A name the OAuth rules let tokens travel to over plain http: exactly `localhost` or a
/// loopback address, never `*.localhost`.
pub fn loopback_name(host: []const u8) bool {
    std.debug.assert(host.len <= address_len_max);

    return std.mem.eql(u8, host, "localhost") or std.mem.startsWith(u8, host, "127.") or
        std.mem.eql(u8, host, "[::1]");
}

/// Whether a `Host` header is one of those, its port aside.
pub fn host_is_loopback(host: []const u8) bool {
    std.debug.assert(host.len <= 64 << 10);

    const bracketed = host.len > 0 and host[0] == '[';
    const name_end = if (bracketed)
        (std.mem.indexOfScalar(u8, host, ']') orelse return false) + 1
    else
        std.mem.indexOfScalar(u8, host, ':') orelse host.len;

    return name_end <= address_len_max and loopback_name(host[0..name_end]);
}

/// Whether a `Host` header names this machine, its port aside.
pub fn host_on_this_machine(host: []const u8) bool {
    std.debug.assert(host.len <= 64 << 10);
    std.debug.assert(address_len_max > 0);

    const bracket_end = if (host.len > 0 and host[0] == '[')
        std.mem.indexOfScalar(u8, host, ']')
    else
        null;
    const name_end = if (bracket_end) |end|
        end + 1
    else
        std.mem.indexOfScalar(u8, host, ':') orelse host.len;
    const name = host[0..name_end];

    return name.len > 0 and name.len <= address_len_max and
        on_this_machine(name);
}

test "a host on this machine is told from one elsewhere" {
    try std.testing.expect(host_on_this_machine("localhost:8080"));
    try std.testing.expect(host_on_this_machine("blog.localhost"));
    try std.testing.expect(host_on_this_machine("publr.local:8080"));
    try std.testing.expect(host_on_this_machine("127.0.0.1:8096"));
    try std.testing.expect(host_on_this_machine("[::1]:8080"));
    try std.testing.expect(!host_on_this_machine("example.com"));
    try std.testing.expect(!host_on_this_machine("localhost.example.com:8080"));
    try std.testing.expect(!host_on_this_machine(""));
}
