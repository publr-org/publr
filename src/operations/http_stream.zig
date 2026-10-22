//! A response read piece by piece, as it arrives: `http.stream` sends the request and
//! answers once its head is in, `http.read` hands over what has come since. How a model
//! provider shows a reply as it is written. Only where a process holds the open responses
//! across a plugin's calls (`ctx.streams`): an agent's.

const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("../sdk.zig");
const http = @import("http.zig");
const guards = @import("http_guard.zig");
const request_log = @import("http_log.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const streams_max: u32 = 2;
const transfer_bytes: u32 = 16 << 10;
const refused_body_bytes_max: u32 = 64 << 10;

/// The responses open in one process, each until it ends or the process is done.
pub const Streams = struct {
    open: [streams_max]?*Open = @splat(null),

    pub fn deinit(streams: *Streams) void {
        std.debug.assert(streams_max > 0);

        for (&streams.open) |*slot| {
            if (slot.*) |open| {
                open.close();
                slot.* = null;
            }
        }
    }
};

/// Nothing is ever open in the browser or a plugin's sandbox: there is no client there.
const native = !builtin.cpu.arch.isWasm();
const Open = if (native) NativeOpen else struct {
    fn close(open: *@This()) void {
        _ = open;
    }
};

const NativeOpen = struct {
    arena_state: std.heap.ArenaAllocator,
    client: std.http.Client,
    request: std.http.Client.Request,
    response: std.http.Client.Response,
    reader: *std.Io.Reader,
    transfer: [transfer_bytes]u8,
    filling: http.Filling,

    fn close(open: *Open) void {
        std.debug.assert(transfer_bytes > 0);

        open.request.deinit();
        open.client.deinit();
        open.arena_state.deinit();
        std.heap.page_allocator.destroy(open);
    }
};

const no_streams: sdk.operation.Failure = .{
    .name = "NoStreams",
    .status = 409,
    .message = "A response is read piece by piece only where an agent runs a turn",
};

pub const Stream = struct {
    pub const name = "http.stream";
    pub const plugins_only = true;
    pub const description = "Send a request out and read its answer as it arrives";
    pub const details =
        \\As `http.fetch`, under the same grant and domains, but answers once the response's
        \\head is in: its status and a `handle` that `http.read` reads the body through, a
        \\piece at a time, as it comes (a model's reply as it is written). A status other
        \\than 200 answers with the body at once and no handle. Only in an agent's process.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = http.Fetch.In;
    pub const Out = struct {
        status: u16,
        handle: u32 = 0,
        body: []const u8 = "",
    };
    pub const example: In = http.Fetch.example;
    pub const example_out: Out = .{
        .status = 200,
        .handle = 1,
    };
    pub const field_docs = http.Fetch.field_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(streams_max > 0);

        if (!native) {
            return error.Unavailable;
        }

        const fetcher = http.fetcher_of(ctx) orelse return error.Denied;
        const Method = std.http.Method;
        const method = std.meta.stringToEnum(Method, in.method) orelse return error.Invalid;
        const uri = std.Uri.parse(in.url) catch return error.Invalid;

        if (in.headers.len > http.headers_max or in.body.len > http.body_bytes_max) {
            return error.Invalid;
        }

        const guard = http.guard_of(ctx, fetcher);

        if (guards.refusal_of_name(guard, uri)) |refusal| {
            request_log.refused(ctx, fetcher.name, in.method, uri, refusal);

            return ctx.fail(http.not_allowed);
        }

        const held = ctx.streams orelse return ctx.fail(no_streams);
        const streams: *Streams = @ptrCast(@alignCast(held));
        const slot = free_slot(streams) orelse return error.Conflict;

        const filling = try http.Filling.of(ctx, fetcher.access, in);
        const open = try opened(ctx, method, filling, guard, .{
            .plugin = fetcher.name,
            .uri = uri,
        });

        if (open.response.head.status != .ok) {
            defer open.close();

            const status: u16 = @intFromEnum(open.response.head.status);

            return .{
                .status = status,
                .body = try rest_of(ctx, open),
            };
        }

        streams.open[slot] = open;

        return .{
            .status = 200,
            .handle = slot + 1,
        };
    }
};

pub const Read = struct {
    pub const name = "http.read";
    pub const plugins_only = true;
    pub const description = "Read what has arrived of a streamed response";
    pub const details =
        \\The next piece of the body `http.stream` opened, as much as has arrived (at least a
        \\byte, up to 16 KiB), waiting until some has; `done` once it has all come, and the
        \\handle is closed.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        handle: u32,
    };
    pub const Out = struct {
        data: []const u8,
        done: bool,
    };
    pub const example: In = .{
        .handle = 1,
    };
    pub const example_out: Out = .{
        .data = "event: ping\ndata: {}\n\n",
        .done = false,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .handle = "What `http.stream` answered",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(streams_max > 0);

        if (!native) {
            return error.Unavailable;
        }

        if (ctx.caller != .plugin) {
            return error.Denied;
        }

        const held = ctx.streams orelse return ctx.fail(no_streams);
        const streams: *Streams = @ptrCast(@alignCast(held));

        if (in.handle == 0 or in.handle > streams_max) {
            return error.Invalid;
        }

        const open = streams.open[in.handle - 1] orelse return error.NotFound;
        const piece = open.reader.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => {
                open.close();
                streams.open[in.handle - 1] = null;

                return .{
                    .data = "",
                    .done = true,
                };
            },
            error.ReadFailed => return ctx.fail(http.unreachable_failure),
        };
        const data = try open.filling.scrub(ctx, ctx.arena.dupe(u8, piece) catch {
            return error.OutOfMemory;
        });

        open.reader.toss(piece.len);

        return .{
            .data = data,
            .done = false,
        };
    }
};

fn free_slot(streams: *const Streams) ?u32 {
    std.debug.assert(streams_max > 0);

    for (streams.open, 0..) |slot, index| {
        if (slot == null) {
            return @intCast(index);
        }
    }

    return null;
}

/// Who sends a request, and its address as written (secrets unfilled), for the log.
const Shown = struct {
    plugin: []const u8,
    uri: std.Uri,
};

/// The request sent and the response's head read, in memory of its own that outlives this
/// call.
fn opened(
    ctx: *Ctx,
    method: std.http.Method,
    filling: http.Filling,
    guard: guards.Guard,
    shown: Shown,
) Error!*Open {
    std.debug.assert(filling.url.len > 0);
    std.debug.assert(shown.plugin.len > 0);

    const plugin = shown.plugin;

    const open = std.heap.page_allocator.create(Open) catch return error.OutOfMemory;

    open.arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    open.filling = filling;
    open.client = .{
        .allocator = open.arena_state.allocator(),
        .io = ctx.io,
    };

    var checked: guards.Checked = .{};

    sent(open, method, guard, &checked) catch |err| {
        std.log.warn("http.stream {s}: {t}", .{ plugin, err });
        open.client.deinit();
        open.arena_state.deinit();
        std.heap.page_allocator.destroy(open);

        if (checked.refusal) |refusal| {
            request_log.refused(ctx, plugin, @tagName(method), shown.uri, refusal);

            return ctx.fail(http.not_allowed);
        }

        return ctx.fail(http.unreachable_failure);
    };

    const line = std.fmt.allocPrint(ctx.arena, "{s} {s}{s} {d} (streamed)", .{
        @tagName(method),
        guards.host_text(shown.uri),
        guards.path_text(shown.uri),
        @intFromEnum(open.response.head.status),
    }) catch return error.OutOfMemory;

    request_log.line(ctx, plugin, line);

    open.reader = open.response.reader(&open.transfer);

    return open;
}

/// Sent through the guard: a redirect comes back as it is, never followed.
fn sent(open: *Open, method: std.http.Method, guard: guards.Guard, checked: *guards.Checked) !void {
    std.debug.assert(open.filling.url.len > 0);
    std.debug.assert(checked.refusal == null);

    const uri = try std.Uri.parse(open.filling.url);
    const connection = try guards.connect(&open.client, guard, uri, checked);

    open.request = try open.client.request(method, uri, .{
        .connection = connection,
        .redirect_behavior = .unhandled,
        // Read as it arrives, a piece at a time: never compressed.
        .headers = .{
            .accept_encoding = .{
                .override = "identity",
            },
        },
        .extra_headers = open.filling.headers,
        .keep_alive = false,
    });
    errdefer open.request.deinit();

    const body = open.filling.body;

    if (body.len > 0) {
        open.request.transfer_encoding = .{
            .content_length = body.len,
        };

        var writer = try open.request.sendBodyUnflushed(&.{});

        try writer.writer.writeAll(body);
        try writer.end();
        try open.request.connection.?.flush();
    } else {
        try open.request.sendBodiless();
    }

    open.response = try open.request.receiveHead(&.{});
}

/// What a refused request answered, whole.
fn rest_of(ctx: *Ctx, open: *Open) Error![]const u8 {
    std.debug.assert(refused_body_bytes_max > 0);

    const limit: std.Io.Limit = .limited(refused_body_bytes_max);
    const body = open.reader.allocRemaining(ctx.arena, limit) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => ctx.fail(http.unreachable_failure),
        };
    };

    return open.filling.scrub(ctx, body);
}
