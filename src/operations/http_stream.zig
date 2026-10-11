//! A response read piece by piece, as it arrives: `http.stream` sends the request and
//! answers once its head is in, `http.read` hands over what has come since. How a model
//! provider shows a reply as it is written. Only where a process holds the open responses
//! across a plugin's calls (`ctx.streams`): an agent's.

const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("../sdk.zig");
const http = @import("http.zig");

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

        const plugin = switch (ctx.caller) {
            .plugin => |plugin| plugin,
            else => return error.Denied,
        };
        const Method = std.http.Method;
        const method = std.meta.stringToEnum(Method, in.method) orelse return error.Invalid;
        const host = http.host_of(in.url) orelse return error.Invalid;

        if (in.headers.len > http.headers_max or in.body.len > http.body_bytes_max) {
            return error.Invalid;
        }

        if (!http.allowed(ctx, plugin.name, host)) {
            return ctx.fail(http.not_allowed);
        }

        const held = ctx.streams orelse return ctx.fail(no_streams);
        const streams: *Streams = @ptrCast(@alignCast(held));
        const slot = free_slot(streams) orelse return error.Conflict;

        const open = try opened(ctx, method, try http.Filling.of(ctx, plugin, in));

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

/// The request sent and the response's head read, in memory of its own that outlives this
/// call.
fn opened(ctx: *Ctx, method: std.http.Method, filling: http.Filling) Error!*Open {
    std.debug.assert(filling.url.len > 0);

    const open = std.heap.page_allocator.create(Open) catch return error.OutOfMemory;

    open.arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    open.filling = filling;
    open.client = .{
        .allocator = open.arena_state.allocator(),
        .io = ctx.io,
    };

    sent(ctx, open, method) catch |err| {
        std.log.warn("http.stream {s}: {t}", .{ ctx.plugin, err });
        open.client.deinit();
        open.arena_state.deinit();
        std.heap.page_allocator.destroy(open);

        return ctx.fail(http.unreachable_failure);
    };

    open.reader = open.response.reader(&open.transfer);

    return open;
}

fn sent(ctx: *Ctx, open: *Open, method: std.http.Method) !void {
    std.debug.assert(open.filling.url.len > 0);
    _ = ctx;

    const uri = try std.Uri.parse(open.filling.url);

    open.request = try open.client.request(method, uri, .{
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
