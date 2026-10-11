//! An outgoing request that gives up: `serve` answers one request at a time, so a server
//! that never answers would hold every other one, the admin and the agent included. The
//! request runs in a thread of its own, into memory of its own; the caller waits at most
//! the time limit, then goes on. A request given up on is never canceled (std's client
//! cannot be canceled mid-answer): it ends on its own and frees what it holds.

const std = @import("std");

/// How long one request may take, connecting to the last byte.
pub const timeout_ms: u32 = 20_000;
/// How often a caller looks whether its request ended.
const look_every_ms: u32 = 25;

pub const Error = error{ TimedOut, Unreachable, TooBig, OutOfMemory };

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

const State = enum(u8) { running, done, given_up };

/// One request and what it answered, in memory of its own: freed by the caller once it
/// ended in time, or by itself once it ends after the caller gave up.
const Job = struct {
    arena_state: std.heap.ArenaAllocator,
    io: std.Io,
    request: Request,
    state: std.atomic.Value(State) = .init(.running),
    status: std.http.Status = .ok,
    body: []const u8 = "",
    failed: ?Error = null,

    fn run(job: *Job) void {
        std.debug.assert(job.request.url.len > 0);

        job.fetch();

        // Whoever comes second frees: the caller if it is still waiting, else the job.
        if (job.state.cmpxchgStrong(.running, .done, .acq_rel, .acquire)) |_| {
            job.arena_state.deinit();
            std.heap.page_allocator.destroy(job);
        }
    }

    fn fetch(job: *Job) void {
        std.debug.assert(job.request.body_max > 0);

        const arena = job.arena_state.allocator();
        const buffer = arena.alloc(u8, job.request.body_max) catch {
            job.failed = error.OutOfMemory;
            return;
        };
        var answer: std.Io.Writer = .fixed(buffer);
        var client: std.http.Client = .{
            .allocator = arena,
            .io = job.io,
        };
        defer client.deinit();

        const result = client.fetch(.{
            .location = .{
                .url = job.request.url,
            },
            .method = job.request.method,
            .payload = job.request.payload,
            .keep_alive = false,
            .extra_headers = job.request.headers,
            .response_writer = &answer,
        }) catch |err| {
            job.failed = if (err == error.WriteFailed) error.TooBig else error.Unreachable;
            return;
        };

        job.status = result.status;
        job.body = answer.buffered();
    }
};

/// `request`, answered within `limit_ms`, its body copied into `allocator`.
pub fn fetch(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: Request,
    limit_ms: u32,
) Error!Answer {
    std.debug.assert(limit_ms > 0 and limit_ms <= 10 * 60 * 1000);
    std.debug.assert(request.url.len > 0);

    const job = try start(io, request);
    var waited_ms: u32 = 0;

    while (job.state.load(.acquire) == .running and waited_ms < limit_ms) {
        std.Io.sleep(io, .fromMilliseconds(look_every_ms), .awake) catch break;
        waited_ms += look_every_ms;
    }

    // Still running: given up on, it frees itself when it ends.
    if (job.state.cmpxchgStrong(.running, .given_up, .acq_rel, .acquire) == null) {
        return error.TimedOut;
    }

    defer {
        job.arena_state.deinit();
        std.heap.page_allocator.destroy(job);
    }

    if (job.failed) |failure| {
        return failure;
    }

    return .{
        .status = job.status,
        .body = allocator.dupe(u8, job.body) catch return error.OutOfMemory,
    };
}

/// The job, its request copied into its own memory, running in a thread of its own.
fn start(io: std.Io, request: Request) Error!*Job {
    std.debug.assert(request.body_max > 0);

    const job = std.heap.page_allocator.create(Job) catch return error.OutOfMemory;

    job.* = .{
        .arena_state = .init(std.heap.page_allocator),
        .io = io,
        .request = request,
    };

    errdefer {
        job.arena_state.deinit();
        std.heap.page_allocator.destroy(job);
    }

    const arena = job.arena_state.allocator();
    const headers = arena.alloc(std.http.Header, request.headers.len) catch {
        return error.OutOfMemory;
    };

    for (request.headers, headers) |given, *kept| {
        kept.* = .{
            .name = arena.dupe(u8, given.name) catch return error.OutOfMemory,
            .value = arena.dupe(u8, given.value) catch return error.OutOfMemory,
        };
    }

    job.request.url = arena.dupe(u8, request.url) catch return error.OutOfMemory;
    job.request.headers = headers;

    if (request.payload) |payload| {
        job.request.payload = arena.dupe(u8, payload) catch return error.OutOfMemory;
    }

    const thread = std.Thread.spawn(.{}, Job.run, .{job}) catch return error.Unreachable;

    thread.detach();

    return job;
}

test "a server that never answers is given up on" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Listens, never answers: what a stuck image host looks like.
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);

    const port = server.socket.address.getPort();
    var url_buffer: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/x.jpg", .{port});

    try std.testing.expectError(error.TimedOut, fetch(io, std.testing.allocator, .{
        .url = url,
        .body_max = 1024,
    }, 300));
}
