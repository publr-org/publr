//! A command sent from another machine: `publr --site <address> <command>` posts its words to
//! `/api/cli` with a device's token, and this Publr runs them as that device through the same
//! CLI. The words are read here, not there, so a project's plugins answer with their own
//! commands whoever asks, from wherever. `server/login.zig` gets the token.
const std = @import("std");
const http = @import("../lib/http.zig");
const cli = @import("../adapters/cli.zig");
const identity_module = @import("../adapters/rest/identity.zig");
const registry = @import("registry.zig");
const sdk = @import("../sdk.zig");
const credentials = @import("credentials.zig");
const Project = @import("project.zig").Project;

pub const route = "/api/cli";
const body_bytes_max: u32 = 1 << 20;

pub const Envelope = struct { args: []const []const u8 };
pub const Answer = struct { code: u8, out: []const u8, err: []const u8 };

/// `POST /api/cli`: a device's command, run as the device; answered with its exit code,
/// output and errors. Anyone else is told to sign in.
pub fn handle(
    request: *http.Request,
    response: *http.Response,
    ctx: *http.Context,
) http.Error!void {
    std.debug.assert(ctx.user_data != null);
    std.debug.assert(request.method() == .post);

    const project = Project.of(ctx);
    const identity = identity_module.identify(request, ctx.arena, project);

    if (identity.caller != .token) {
        return response.json(.unauthorized, .{
            .@"error" = "device_required",
            .message = "Sign in with `publr login <address>` first",
        });
    }

    if (request.body.len > body_bytes_max) {
        return response.json(.payload_too_large, .{ .@"error" = "too_large" });
    }

    const envelope = std.json.parseFromSliceLeaky(Envelope, ctx.arena, request.body, .{}) catch {
        return response.json(.bad_request, .{ .@"error" = "invalid_body" });
    };
    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    var err: std.Io.Writer.Allocating = .init(ctx.arena);
    const code = cli.CLI(registry.SDK).run(.{
        .db = project.connection,
        .io = project.io,
        .arena = ctx.arena,
        .auth = project.auth,
        .now_ms = sdk.context.wall_clock_ms(project.io),
        .err = &err.writer,
        .sandboxed_plugins = project.sandboxed_plugins,
        .plugin_states = project.plugin_states,
        .files = project.files,
        .apps = if (project.apps_host) |host| host.folder() else null,
        .builder = project.builder,
        .device = identity.caller,
    }, envelope.args, &out.writer) catch |failure| blk: {
        err.writer.print("publr: {s}\n", .{@errorName(failure)}) catch {
            return response.text(.internal_server_error, @errorName(failure));
        };
        break :blk 1;
    };

    try response.json(.ok, Answer{ .code = code, .out = out.written(), .err = err.written() });
}

/// The command run by the Publr at `address` with the token this machine keeps for it: its
/// exit code, its output written to `out` and its errors to stderr.
pub fn forward(
    init: std.process.Init,
    address: []const u8,
    args: []const []const u8,
    out: *std.Io.Writer,
) !u8 {
    std.debug.assert(address.len > 0);
    std.debug.assert(args.len > 0);

    const arena = init.arena.allocator();
    const site = try credentials.find(init, address) orelse {
        std.debug.print("publr: not signed in to {s}; run \"publr login {s}\"\n", .{
            address,
            address,
        });
        return 1;
    };
    const payload = try std.json.Stringify.valueAlloc(arena, Envelope{ .args = args }, .{});
    const reply = try post(init.io, arena, .{
        .url = try std.fmt.allocPrint(arena, "{s}{s}", .{ site.address, route }),
        .payload = payload,
        .token = site.token,
    });

    if (reply.status == .unauthorized) {
        std.debug.print("publr: {s} no longer accepts this device; run \"publr login {s}\"\n", .{
            site.address,
            site.address,
        });
        return 1;
    }

    if (reply.status != .ok) {
        std.debug.print("publr: {s} answered {d}\n", .{ site.address, @intFromEnum(reply.status) });
        return 1;
    }

    const answer = try std.json.parseFromSliceLeaky(Answer, arena, reply.body, .{});

    try out.writeAll(answer.out);
    std.debug.print("{s}", .{answer.err});

    return answer.code;
}

pub const Post = struct { url: []const u8, payload: []const u8, token: ?[]const u8 = null };
pub const Reply = struct { status: std.http.Status, body: []const u8 };

/// A JSON body posted to `url`, with a device's token when there is one.
pub fn post(io: std.Io, arena: std.mem.Allocator, request: Post) !Reply {
    std.debug.assert(request.url.len > 0);
    std.debug.assert(request.payload.len > 0);

    var body: std.Io.Writer.Allocating = .init(arena);
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    const bearer = if (request.token) |token|
        try std.fmt.allocPrint(arena, "Bearer {s}", .{token})
    else
        "";
    const authorization: []const std.http.Header = if (request.token != null)
        &.{.{ .name = "Authorization", .value = bearer }}
    else
        &.{};
    const result = try client.fetch(.{
        .location = .{ .url = request.url },
        .method = .POST,
        .payload = request.payload,
        .keep_alive = false,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .extra_headers = authorization,
        .response_writer = &body.writer,
    });

    return .{ .status = result.status, .body = body.written() };
}

/// The address to use for `address`. An `https://` one whose port answers plain HTTP (a
/// `publr serve`, which speaks no TLS) would leave the TLS handshake waiting forever: on
/// this machine its `http://` address is used, saying so; elsewhere it is refused with why.
pub fn settle(io: std.Io, arena: std.mem.Allocator, address: []const u8) ![]const u8 {
    std.debug.assert(address.len > 0);

    const prefix = "https://";

    if (!std.mem.startsWith(u8, address, prefix)) {
        return address;
    }

    const rest = address[prefix.len..];
    const authority = rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':');
    const host = if (colon) |at| authority[0..at] else authority;
    const port = if (colon) |at| std.fmt.parseInt(u16, authority[at + 1 ..], 10) catch 443 else 443;

    if (!plain_http(io, host, port)) {
        return address;
    }

    const plain = try std.fmt.allocPrint(arena, "http://{s}", .{rest});

    if (!credentials.on_this_machine(host)) {
        std.debug.print("publr: {s} answers plain http, not https; use {s} if you mean it\n", .{
            address,
            plain,
        });
        return error.NotHttps;
    }

    std.debug.print("publr: {s} answers plain http (a `publr serve`): using {s}\n", .{
        address,
        plain,
    });

    return plain;
}

/// Whether `host:port` answers a plain HTTP request. A TLS server refuses those bytes at
/// once, so neither answer waits long.
fn plain_http(io: std.Io, host: []const u8, port: u16) bool {
    std.debug.assert(port > 0);

    const name = std.Io.net.HostName.init(host) catch return false;
    const stream = name.connect(io, port, .{ .mode = .stream }) catch return false;
    defer stream.close(io);

    var write_buffer: [64]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);

    writer.interface.writeAll("HEAD / HTTP/1.0\r\n\r\n") catch return false;
    writer.interface.flush() catch return false;

    var read_buffer: [64]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    const head = reader.interface.peek(5) catch return false;

    return std.mem.eql(u8, head, "HTTP/");
}
