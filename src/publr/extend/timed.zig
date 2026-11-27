//! `publr.Host.timed`: a built-in plugin's own request to another server that gives up after
//! a time limit, outside any plugin's `http.fetch` grant (no guard, no secrets filled in).
//! For a built-in plugin's own calls, such as the dashboard calling a project at its own
//! address; a plugin calling out as itself uses `ctx.fetch` in queued work.
const std = @import("std");
const core = @import("../../operations/http_timed.zig");

/// How long one request may take at most, connecting to the last byte.
pub const timeout_ms: u32 = core.timeout_ms;

pub const Error = error{ TimedOut, Unreachable, TooBig, OutOfMemory, Refused };

pub const Request = struct {
    url: []const u8,
    method: std.http.Method = .GET,
    payload: ?[]const u8 = null,
    headers: []const std.http.Header = &.{},
    /// The answer's body, at most.
    body_max: u32,
};

pub const Answer = struct {
    status: std.http.Status,
    /// In the caller's allocator.
    body: []u8,
};

/// `request` answered within `limit_ms` (at most `timeout_ms`), its body copied into
/// `allocator`. The request runs in a thread of its own; the caller waits at most the limit.
pub fn fetch(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: Request,
    limit_ms: u32,
) Error!Answer {
    std.debug.assert(limit_ms > 0 and limit_ms <= timeout_ms);
    std.debug.assert(request.url.len > 0);

    const answer = try core.fetch(io, allocator, .{
        .url = request.url,
        .method = request.method,
        .payload = request.payload,
        .headers = request.headers,
        .body_max = request.body_max,
    }, limit_ms);

    return .{
        .status = answer.status,
        .body = answer.body,
    };
}
