//! What core itself downloads (a file to import, a provider's catalog): a plain GET of a
//! public address, under the same address rules as a plugin's calls: never this machine,
//! and in production never a local or private address, checked where it resolves.
const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("../sdk.zig");
const timed = @import("http_timed.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;

pub const Downloaded = struct {
    status: u16,
    bytes: []const u8,
    /// What the caller frees with its allocator; `bytes` lie in it.
    buffer: []u8,
};

pub const not_public: sdk.operation.Failure = .{
    .name = "NotPublic",
    .status = 422,
    .message = "Only an http or https address on the web: never this machine or its network",
};

const unreachable_failure: sdk.operation.Failure = .{
    .name = "Unreachable",
    .status = 502,
    .message = "The request did not go through",
};

/// `url`, https or http, on a public host, up to `bytes_max`, into `allocator`'s memory.
/// Queued work only, as a plugin's `http.fetch` is: nothing a request waits on downloads.
pub fn download(
    ctx: *Ctx,
    allocator: std.mem.Allocator,
    url: []const u8,
    bytes_max: u32,
) Error!Downloaded {
    std.debug.assert(bytes_max > 0);
    std.debug.assert(url.len > 0);

    const uri = std.Uri.parse(url) catch return error.Invalid;
    const host = switch (uri.host orelse return error.Invalid) {
        .raw, .percent_encoded => |text| text,
    };
    const web = std.mem.eql(u8, uri.scheme, "https") or std.mem.eql(u8, uri.scheme, "http");

    if (!web or !public_host(host)) {
        return ctx.fail(not_public);
    }

    if (ctx.job.len == 0) {
        return ctx.fail(@import("http.zig").not_queued);
    }

    if (builtin.os.tag == .wasi) {
        return error.Unavailable;
    }

    var trace: timed.Trace = .{
        .arena = ctx.arena,
    };
    const result = timed.fetch_traced(ctx.io, allocator, .{
        .url = url,
        .body_max = bytes_max,
        .guard = .{
            .domains = null,
            .rule = ctx.outside,
        },
    }, timed.timeout_ms, &trace) catch |err| {
        if (err == error.Refused) {
            return ctx.fail(not_public);
        }

        std.log.warn("download {s}: {t}", .{ url, err });

        return ctx.fail(unreachable_failure);
    };

    return .{
        .status = @intFromEnum(result.status),
        .bytes = result.body,
        .buffer = result.body,
    };
}

/// A host on the web by its name, never this machine or its network: what may be downloaded
/// from.
pub fn public_host(host: []const u8) bool {
    std.debug.assert(host.len <= 64 << 10);

    const outside = @import("../model/outside.zig");

    return host.len > 0 and !outside.this_machine(host) and !on_its_network(host);
}

/// A private address by its name: never downloaded from on the server's behalf.
fn on_its_network(host: []const u8) bool {
    std.debug.assert(host.len <= 64 << 10);

    const prefixes = [_][]const u8{ "10.", "192.168.", "169.254.", "0.", "[fc", "[fd", "[fe80" };

    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, host, prefix)) {
            return true;
        }
    }

    if (std.mem.startsWith(u8, host, "172.")) {
        const rest = host[4..];
        const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return false;
        const second = std.fmt.parseInt(u8, rest[0..dot], 10) catch return false;

        return second >= 16 and second <= 31;
    }

    return std.mem.endsWith(u8, host, ".local") or std.mem.endsWith(u8, host, ".internal");
}

test "a public host by name: never this machine or a private network's" {
    try std.testing.expect(public_host("example.com"));
    try std.testing.expect(!public_host("localhost"));
    try std.testing.expect(!public_host("10.0.0.1"));
    try std.testing.expect(!public_host("172.20.1.1"));
    try std.testing.expect(public_host("172.40.1.1"));
    try std.testing.expect(!public_host("printer.local"));
}

test "core downloads in queued work only: never in a request" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.system);

    try std.testing.expectError(error.Failed, download(
        &ctx,
        std.testing.allocator,
        "https://example.com/harbour.png",
        1024,
    ));
    try std.testing.expectEqualStrings("NotQueued", ctx.failure.?.name);
}
