//! A guarded request, hop by hop: each one connected through the guard, a redirect followed
//! only where the guard lets the next hop go, headers dropped once the host changes.
const std = @import("std");
const timed = @import("http_timed.zig");
const guard_module = @import("http_guard.zig");

const Client = std.http.Client;
const Guard = guard_module.Guard;

const Leg = struct {
    uri: std.Uri,
    method: std.http.Method,
    payload: ?[]const u8,
    headers: []const std.http.Header,
};

/// Runs `job`'s request under `guard`, its hops kept in `job.trace`.
pub fn run(job: *timed.Job, guard: Guard) void {
    std.debug.assert(job.request.url.len > 0);
    std.debug.assert(guard_module.hops_max > 0);

    const arena = job.arena_state.allocator();
    var client: Client = .{
        .allocator = arena,
        .io = job.io,
    };
    defer client.deinit();

    var leg: Leg = .{
        .uri = std.Uri.parse(job.request.url) catch {
            job.failed = error.Unreachable;
            return;
        },
        .method = job.request.method,
        .payload = job.request.payload,
        .headers = job.request.headers,
    };

    for (0..guard_module.hops_max + 1) |hop| {
        const location = one(job, &client, guard, leg) orelse return;
        const last = hop == guard_module.hops_max;
        const onward = guard_module.next(arena, leg.uri, location) orelse return;

        if (last) {
            return;
        }

        const host_changed = !std.ascii.eqlIgnoreCase(
            guard_module.host_text(onward),
            guard_module.host_text(leg.uri),
        );
        const keeps_method = job.status == .temporary_redirect or
            job.status == .permanent_redirect;

        leg.uri = onward;
        leg.headers = if (host_changed) &.{} else leg.headers;

        if (!keeps_method) {
            leg.method = if (leg.method == .HEAD) .HEAD else .GET;
            leg.payload = null;
        }
    }
}

/// One hop: its answer in `job`, and where it redirects to (copied into the job's memory),
/// null when it is the last one.
fn one(job: *timed.Job, client: *Client, guard: Guard, leg: Leg) ?[]const u8 {
    std.debug.assert(job.trace.count < job.trace.hops.len);

    const arena = job.arena_state.allocator();
    const kept = &job.trace.hops[job.trace.count];

    job.trace.count += 1;
    kept.* = .{
        .host = guard_module.host_text(leg.uri),
        .path = guard_module.path_text(leg.uri),
        .status = 0,
    };

    var checked: guard_module.Checked = .{};
    const connection = guard_module.connect(client, guard, leg.uri, &checked) catch |err| {
        kept.refusal = checked.refusal;
        job.failed = switch (err) {
            error.Refused => error.Refused,
            error.OutOfMemory => error.OutOfMemory,
            error.Unreachable => error.Unreachable,
        };

        return null;
    };

    var request = client.request(leg.method, leg.uri, .{
        .connection = connection,
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .extra_headers = leg.headers,
    }) catch {
        job.failed = error.Unreachable;
        return null;
    };
    defer request.deinit();

    var response = sent(&request, leg.payload) catch {
        job.failed = error.Unreachable;
        return null;
    };

    job.status = response.head.status;
    kept.status = @intFromEnum(response.head.status);

    if (response.head.status.class() == .redirect) {
        const location = response.head.location orelse return body_read(job, &response);

        return arena.dupe(u8, location) catch {
            job.failed = error.OutOfMemory;
            return null;
        };
    }

    return body_read(job, &response);
}

fn sent(request: *Client.Request, payload: ?[]const u8) !Client.Response {
    std.debug.assert(request.redirect_behavior == .unhandled);

    if (payload) |body| {
        request.transfer_encoding = .{
            .content_length = body.len,
        };

        var writer = try request.sendBodyUnflushed(&.{});

        try writer.writer.writeAll(body);
        try writer.end();
        try request.connection.?.flush();
    } else {
        try request.sendBodiless();
    }

    return request.receiveHead(&.{});
}

/// The answer's body into the job, up to its limit; always null: nothing follows.
fn body_read(job: *timed.Job, response: *Client.Response) ?[]const u8 {
    std.debug.assert(job.request.body_max > 0);

    const arena = job.arena_state.allocator();
    const buffer = arena.alloc(u8, job.request.body_max) catch {
        job.failed = error.OutOfMemory;
        return null;
    };
    const window: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => arena.alloc(u8, std.compress.zstd.default_window_len) catch &.{},
        .deflate, .gzip => arena.alloc(u8, std.compress.flate.max_window_len) catch &.{},
        .compress => {
            job.failed = error.Unreachable;
            return null;
        },
    };
    var answer: std.Io.Writer = .fixed(buffer);
    var transfer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer, &decompress, window);

    _ = reader.streamRemaining(&answer) catch |err| {
        job.failed = if (err == error.WriteFailed) error.TooBig else error.Unreachable;
        return null;
    };
    job.body = answer.buffered();

    return null;
}

test "a guarded request reaches a listed host on this machine in development" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);

    const port = server.socket.address.getPort();
    var url_buffer: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "http://localhost:{d}/x", .{port});
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var trace: timed.Trace = .{
        .arena = arena_state.allocator(),
    };

    // Production: this machine is refused before anything is sent.
    try std.testing.expectError(error.Refused, timed.fetch_traced(io, std.testing.allocator, .{
        .url = url,
        .body_max = 1024,
        .guard = .{
            .domains = &.{"localhost"},
            .rule = .{},
        },
    }, 2000, &trace));
    try std.testing.expectEqual(@as(u32, 1), trace.count);
    try std.testing.expect(trace.hops[0].refusal.? == .local);
    try std.testing.expectEqualStrings("localhost", trace.hops[0].host);
}

/// Answers one request on `server` with `reply`, whatever was asked.
fn answer_once(io: std.Io, server: *std.Io.net.Server, reply: []const u8) void {
    std.debug.assert(reply.len > 0);

    const stream = server.accept(io) catch return;
    defer stream.close(io);

    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);

    for (0..64) |_| {
        const line = reader.interface.takeDelimiterExclusive('\n') catch return;

        reader.interface.toss(1);

        if (line.len <= 1) {
            break;
        }
    }

    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);

    writer.interface.writeAll(reply) catch return;
    writer.interface.flush() catch return;
}

test "development reaches a listed host here; a redirect to an unlisted host is refused" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);

    const port = server.socket.address.getPort();
    const url = try std.fmt.allocPrint(arena, "http://localhost:{d}/x", .{port});
    const guard: Guard = .{
        .domains = &.{"localhost"},
        .rule = .{
            .production = false,
        },
    };
    const ok = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok";
    const answering = try std.Thread.spawn(.{}, answer_once, .{ io, &server, ok });
    var trace: timed.Trace = .{
        .arena = arena,
    };
    const answer = try timed.fetch_traced(io, arena, .{
        .url = url,
        .body_max = 1024,
        .guard = guard,
    }, 5000, &trace);

    answering.join();
    try std.testing.expectEqualStrings("ok", answer.body);
    try std.testing.expectEqual(@as(u16, 200), answer.hops[0].status);

    const moved = "HTTP/1.1 302 Found\r\nLocation: https://elsewhere.example.org/x\r\n" ++
        "Content-Length: 0\r\nConnection: close\r\n\r\n";
    const redirecting = try std.Thread.spawn(.{}, answer_once, .{ io, &server, moved });
    var redirected: timed.Trace = .{
        .arena = arena,
    };

    try std.testing.expectError(error.Refused, timed.fetch_traced(io, arena, .{
        .url = url,
        .body_max = 1024,
        .guard = guard,
    }, 5000, &redirected));
    redirecting.join();
    try std.testing.expectEqual(@as(u32, 2), redirected.count);
    try std.testing.expectEqual(@as(u16, 302), redirected.hops[0].status);
    try std.testing.expectEqualStrings("elsewhere.example.org", redirected.hops[1].host);
    try std.testing.expect(redirected.hops[1].refusal.? == .not_listed);
}
