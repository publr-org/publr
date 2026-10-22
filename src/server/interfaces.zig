//! The addresses on this machine's own network interfaces, read from the machine itself (no
//! outside lookup): what a plugin's outside call must never reach in production.
const std = @import("std");
const builtin = @import("builtin");
const outside = @import("../model/outside.zig");

const IpAddress = std.Io.net.IpAddress;
const libc = std.c;

const Ifaddrs = extern struct {
    next: ?*Ifaddrs,
    name: [*:0]const u8,
    flags: c_uint,
    addr: ?*const libc.sockaddr,
    netmask: ?*const libc.sockaddr,
    destination: ?*const libc.sockaddr,
    data: ?*anyopaque,
};

extern "c" fn getifaddrs(list: *?*Ifaddrs) c_int;
extern "c" fn freeifaddrs(list: ?*Ifaddrs) void;

const supported = builtin.os.tag == .linux or builtin.os.tag.isDarwin();

/// Every address on the machine's interfaces, at most `buffer.len`; none where they cannot
/// be read.
pub fn all(buffer: []IpAddress) []const IpAddress {
    std.debug.assert(buffer.len <= outside.own_addresses_max * 4);

    if (comptime !supported) {
        return buffer[0..0];
    }

    var list: ?*Ifaddrs = null;

    if (getifaddrs(&list) != 0) {
        return buffer[0..0];
    }

    defer freeifaddrs(list);

    var count: usize = 0;
    var node = list;

    while (node) |item| : (node = item.next) {
        if (count == buffer.len) {
            break;
        }

        const address = address_of(item.addr orelse continue) orelse continue;

        buffer[count] = address;
        count += 1;
    }

    return buffer[0..count];
}

/// The public ones among them, in `arena`: the server's own addresses another name might
/// lead to.
pub fn public(arena: std.mem.Allocator) error{OutOfMemory}![]const IpAddress {
    std.debug.assert(outside.own_addresses_max > 0);

    var buffer: [outside.own_addresses_max * 4]IpAddress = undefined;
    var kept: std.ArrayList(IpAddress) = .empty;

    for (all(&buffer)) |address| {
        if (outside.public(address) and kept.items.len < outside.own_addresses_max) {
            try kept.append(arena, address);
        }
    }

    return kept.items;
}

fn address_of(socket: *const libc.sockaddr) ?IpAddress {
    if (socket.family == libc.AF.INET) {
        const in: *const libc.sockaddr.in = @ptrCast(@alignCast(socket));

        std.debug.assert(in.family == socket.family);

        return .{
            .ip4 = .{
                .bytes = @bitCast(in.addr),
                .port = 0,
            },
        };
    }

    if (socket.family == libc.AF.INET6) {
        const in6: *const libc.sockaddr.in6 = @ptrCast(@alignCast(socket));

        std.debug.assert(in6.family == socket.family);

        return .{
            .ip6 = .{
                .bytes = in6.addr,
                .port = 0,
            },
        };
    }

    return null;
}

test "the machine's own addresses include its loopback" {
    var buffer: [outside.own_addresses_max * 4]IpAddress = undefined;
    const addresses = all(&buffer);

    try std.testing.expect(outside.among(addresses, try IpAddress.parse("127.0.0.1", 0)));

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    for (try public(arena_state.allocator())) |address| {
        try std.testing.expect(outside.public(address));
    }
}
