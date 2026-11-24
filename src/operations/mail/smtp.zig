//! One email handed to an SMTP server: connected to an address the guard allowed, over TLS
//! from the start or after STARTTLS (the certificate checked against the system's), signed
//! in when a user is given (AUTH PLAIN, else LOGIN), then MAIL FROM, RCPT TO for each
//! recipient, DATA with the message as written, QUIT. As `http_timed` does, it runs in a
//! thread of its own, into memory of its own; the caller waits at most the time limit, then
//! goes on, and a conversation given up on ends on its own and frees what it holds.
const std = @import("std");
const guards = @import("../http_guard.zig");
const conversation = @import("conversation.zig");
const outside = @import("../../model/outside.zig");

const HostName = std.Io.net.HostName;
const IpAddress = std.Io.net.IpAddress;
const TlsClient = std.crypto.tls.Client;

/// How long one email may take, connecting to the server's last answer.
pub const timeout_ms: u32 = 30_000;
/// How often a caller looks whether its email went.
const look_every_ms: u32 = 25;
const buffer_bytes: u32 = TlsClient.min_buffer_len + 1024;

/// How the connection is protected: TLS after STARTTLS (port 587), TLS from the start
/// (port 465), or none (development only).
pub const Security = enum { starttls, tls, none };

pub const Request = struct {
    host: []const u8,
    port: u16,
    security: Security,
    /// Empty: the server takes the email without signing in.
    user: []const u8 = "",
    password: []const u8 = "",
    from: []const u8,
    to: []const []const u8,
    /// The message as written (RFC 5322 headers, a blank line, the body).
    message: []const u8,
    /// The name it greets the server with (EHLO).
    greeting: []const u8 = "localhost",
    rule: outside.Rule,
};

/// Where a conversation stopped.
pub const Failure = enum {
    /// The address is refused here (`refusal` says why).
    refused_address,
    /// No connection, or it broke.
    unreachable_server,
    /// TLS could not be set up or the certificate is not the host's.
    tls,
    /// The server has no STARTTLS.
    no_starttls,
    /// The server offers no sign-in Publr speaks (PLAIN, LOGIN).
    no_sign_in,
    /// The server answered no (`said` holds its answer).
    refused,
    out_of_memory,
};

pub const Result = struct {
    /// The server's answer to the message, or to the step it refused.
    said: []const u8 = "",
    failed: ?Failure = null,
    refusal: ?outside.Refusal = null,
};

pub const Error = error{TimedOut} || std.mem.Allocator.Error;

const State = enum(u8) { running, done, given_up };

const Job = struct {
    arena_state: std.heap.ArenaAllocator,
    io: std.Io,
    request: Request,
    state: std.atomic.Value(State) = .init(.running),
    result: Result = .{},

    fn run(job: *Job) void {
        std.debug.assert(job.request.host.len > 0);

        job.result = send_now(job.io, job.arena_state.allocator(), job.request);

        // Whoever comes second frees: the caller if it is still waiting, else the job.
        if (job.state.cmpxchgStrong(.running, .done, .acq_rel, .acquire)) |_| {
            job.arena_state.deinit();
            std.heap.page_allocator.destroy(job);
        }
    }
};

/// `request` sent within `limit_ms`; what the server said copied into `allocator`.
pub fn send(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: Request,
    limit_ms: u32,
) Error!Result {
    std.debug.assert(limit_ms > 0 and limit_ms <= 10 * 60 * 1000);
    std.debug.assert(request.to.len > 0);

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

    var result = job.result;

    result.said = try allocator.dupe(u8, result.said);

    return result;
}

/// The job, its request copied into its own memory, running in a thread of its own.
fn start(io: std.Io, request: Request) Error!*Job {
    std.debug.assert(request.host.len > 0);

    const job = try std.heap.page_allocator.create(Job);

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
    const to = try arena.alloc([]const u8, request.to.len);

    for (request.to, to) |given, *kept| {
        kept.* = try arena.dupe(u8, given);
    }

    job.request.host = try arena.dupe(u8, request.host);
    job.request.user = try arena.dupe(u8, request.user);
    job.request.password = try arena.dupe(u8, request.password);
    job.request.from = try arena.dupe(u8, request.from);
    job.request.message = try arena.dupe(u8, request.message);
    job.request.greeting = try arena.dupe(u8, request.greeting);
    job.request.to = to;

    const thread = std.Thread.spawn(.{}, Job.run, .{job}) catch return error.OutOfMemory;

    thread.detach();

    return job;
}

/// The whole conversation, on this thread.
pub fn send_now(io: std.Io, arena: std.mem.Allocator, request: Request) Result {
    std.debug.assert(request.host.len > 0);

    var result: Result = .{};
    const stream = connected(io, request, &result) orelse return result;
    defer stream.close(io);

    const buffers = arena.alloc(u8, buffer_bytes * 4) catch {
        result.failed = .out_of_memory;
        return result;
    };
    var plain_reader = stream.reader(io, buffers[0..buffer_bytes]);
    var plain_writer = stream.writer(io, buffers[buffer_bytes .. buffer_bytes * 2]);
    var session: conversation.Session = .{
        .io = io,
        .arena = arena,
        .host = request.host,
        .plain_in = &plain_reader.interface,
        .plain_out = &plain_writer.interface,
        .in = &plain_reader.interface,
        .out = &plain_writer.interface,
        .tls_read = buffers[buffer_bytes * 2 .. buffer_bytes * 3],
        .tls_write = buffers[buffer_bytes * 3 .. buffer_bytes * 4],
        .result = &result,
    };

    conversation.converse(&session, request) catch |err| {
        std.debug.assert(err == error.Stop);
        std.debug.assert(result.failed != null);
    };
    session.close();

    return result;
}

fn connected(io: std.Io, request: Request, result: *Result) ?std.Io.net.Stream {
    std.debug.assert(request.port > 0);

    switch (request.rule.egress) {
        .direct => {},
        .off, .through => {
            // The host's proxy carries web requests only.
            result.failed = .refused_address;
            result.refusal = .offline;
            return null;
        },
    }

    const host = HostName.init(request.host) catch {
        result.failed = .unreachable_server;
        return null;
    };
    var checked: guards.Checked = .{};
    const pinned = guards.resolved(io, request.rule, host, request.port, &checked) catch {
        result.failed = if (checked.refusal != null) .refused_address else .unreachable_server;
        result.refusal = checked.refusal;
        return null;
    };
    const options: IpAddress.ConnectOptions = .{
        .mode = .stream,
    };

    if (pinned) |address| {
        return address.connect(io, options) catch {
            result.failed = .unreachable_server;
            return null;
        };
    }

    return host.connect(io, request.port, options) catch {
        result.failed = .unreachable_server;
        return null;
    };
}

/// A server for the tests: answers as a mail server would, signing in with PLAIN, and
/// keeps the message it was given.
const Sink = struct {
    server: std.Io.net.Server,
    io: std.Io,
    message: [2048]u8 = undefined,
    message_len: usize = 0,
    signed_in: bool = false,
    recipients: u32 = 0,

    fn serve(sink: *Sink) void {
        std.debug.assert(sink.message_len == 0);

        const stream = sink.server.accept(sink.io) catch return;
        defer stream.close(sink.io);

        var read_buffer: [2048]u8 = undefined;
        var write_buffer: [2048]u8 = undefined;
        var reader = stream.reader(sink.io, &read_buffer);
        var writer = stream.writer(sink.io, &write_buffer);
        const in = &reader.interface;
        const out = &writer.interface;

        out.writeAll("220 sink ready\r\n") catch return;
        out.flush() catch return;

        while (true) {
            const line = in.takeDelimiterInclusive('\n') catch return;
            const text = std.mem.trimEnd(u8, line, "\r\n");
            const answer: []const u8 = if (std.mem.startsWith(u8, text, "EHLO"))
                "250-sink\r\n250-AUTH PLAIN LOGIN\r\n250 8BITMIME\r\n"
            else if (std.mem.startsWith(u8, text, "AUTH PLAIN ")) blk: {
                // "\0ada\0s3cret"
                sink.signed_in = std.mem.eql(u8, text[11..], "AGFkYQBzM2NyZXQ=");
                break :blk if (sink.signed_in) "235 ok\r\n" else "535 no\r\n";
            } else if (std.mem.startsWith(u8, text, "MAIL FROM:"))
                "250 ok\r\n"
            else if (std.mem.startsWith(u8, text, "RCPT TO:")) blk: {
                sink.recipients += 1;
                break :blk "250 ok\r\n";
            } else if (std.mem.eql(u8, text, "DATA")) blk: {
                out.writeAll("354 go on\r\n") catch return;
                out.flush() catch return;

                while (true) {
                    const body_line = in.takeDelimiterInclusive('\n') catch return;

                    if (std.mem.eql(u8, body_line, ".\r\n")) {
                        break;
                    }

                    const room = sink.message.len - sink.message_len;
                    const kept = @min(room, body_line.len);

                    @memcpy(sink.message[sink.message_len..][0..kept], body_line[0..kept]);
                    sink.message_len += kept;
                }

                break :blk "250 2.0.0 queued as A1\r\n";
            } else if (std.mem.eql(u8, text, "QUIT")) {
                out.writeAll("221 bye\r\n") catch return;
                out.flush() catch return;
                return;
            } else "500 what\r\n";

            out.writeAll(answer) catch return;
            out.flush() catch return;
        }
    }
};

test "an email reaches a server over plain SMTP in development, signed in, dots doubled" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const address = try IpAddress.parse("127.0.0.1", 0);
    var sink: Sink = .{
        .server = try address.listen(io, .{}),
        .io = io,
    };
    defer sink.server.deinit(io);

    const thread = try std.Thread.spawn(.{}, Sink.serve, .{&sink});

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const result = try send(io, arena_state.allocator(), .{
        .host = "127.0.0.1",
        .port = sink.server.socket.address.getPort(),
        .security = .none,
        .user = "ada",
        .password = "s3cret",
        .from = "shop@example.com",
        .to = &.{ "ada@example.com", "bob@example.com" },
        .message = "Subject: Hi\n\nHello\n.hidden dot\n",
        .rule = .{
            .production = false,
        },
    }, 5000);

    thread.join();

    try std.testing.expectEqual(null, result.failed);
    try std.testing.expectEqualStrings("250 2.0.0 queued as A1", result.said);
    try std.testing.expect(sink.signed_in);
    try std.testing.expectEqual(2, sink.recipients);
    try std.testing.expectEqualStrings(
        "Subject: Hi\r\n\r\nHello\r\n..hidden dot\r\n",
        sink.message[0..sink.message_len],
    );
}

test "in production a server on this machine is refused before anything is sent" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const result = send_now(threaded.io(), arena_state.allocator(), .{
        .host = "127.0.0.1",
        .port = 25,
        .security = .starttls,
        .from = "shop@example.com",
        .to = &.{"ada@example.com"},
        .message = "Subject: Hi\n\nHello\n",
        .rule = .{},
    });

    try std.testing.expectEqual(Failure.refused_address, result.failed.?);
}
