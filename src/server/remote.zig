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

pub const Envelope = struct {
    args: []const []const u8,
};
pub const Answer = struct {
    code: u8,
    out: []const u8,
    err: []const u8,
    /// The name of the failure it ended with, empty for none.
    failure: []const u8 = "",
};
/// An answer without a failure's name, as every Publr answered before it had one.
const Plain = struct {
    code: u8,
    out: []const u8,
    err: []const u8,
};
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
        return response.json(.payload_too_large, .{
            .@"error" = "too_large",
        });
    }

    const envelope = std.json.parseFromSliceLeaky(Envelope, ctx.arena, request.body, .{
        .ignore_unknown_fields = true,
    }) catch {
        return response.json(.bad_request, .{
            .@"error" = "invalid_body",
        });
    };

    if (envelope.args.len == 0) {
        return response.json(.bad_request, .{
            .@"error" = "invalid_body",
        });
    }

    const answer = try run_in(project, ctx.arena, identity.caller, envelope.args);

    // Named only when there is one: a CLI from before `failure` reads the plain answer.
    if (answer.failure.len == 0) {
        return response.json(.ok, Plain{
            .code = answer.code,
            .out = answer.out,
            .err = answer.err,
        });
    }

    try response.json(.ok, answer);
}

/// A command's words run here as `device`, through the same CLI as on this machine: its
/// exit code, output and errors. What `/api/cli` and MCP's `run` answer.
pub fn run_words(
    project: *const Project,
    arena: std.mem.Allocator,
    device: sdk.Caller,
    args: []const []const u8,
) error{OutOfMemory}!Answer {
    std.debug.assert(device == .token);
    std.debug.assert(args.len > 0);

    var out: std.Io.Writer.Allocating = .init(arena);
    var err: std.Io.Writer.Allocating = .init(arena);
    var failed: []const u8 = "";
    const code = cli.CLI(registry.SDK).run(
        project.connection,
        project.io,
        arena,
        project.auth,
        args,
        &out.writer,
        .{
            .now_ms = sdk.context.wall_clock_ms(project.io),
            .err = &err.writer,
            .sandboxed_plugins = project.sandboxed_plugins,
            .plugin_states = project.plugin_states,
            .files = project.files,
            .apps = project.apps_folder(),
            .builder = project.builder,
            .agents = project.agents,
            .live = project.live,
            .updater = project.updater,
            .translations = if (project.languages) |languages| languages.view() else null,
            .device = device,
            .failed = &failed,
        },
    ) catch |failure| blk: {
        err.writer.print("publr: {s}\n", .{@errorName(failure)}) catch {
            return error.OutOfMemory;
        };
        break :blk 1;
    };

    return .{
        .code = code,
        .out = out.written(),
        .err = err.written(),
        .failure = failed,
    };
}

/// A command's words as `run_words`, in the copy of this site they name first (`--env <name>`),
/// if they do. That copy is another process with its own database: run through this binary,
/// in this folder, as the device.
pub fn run_in(
    project: *const Project,
    arena: std.mem.Allocator,
    device: sdk.Caller,
    args: []const []const u8,
) error{OutOfMemory}!Answer {
    std.debug.assert(device == .token);
    std.debug.assert(args.len > 0);

    if (args.len < 3 or !std.mem.eql(u8, args[0], "--env")) {
        return run_words(project, arena, device, args);
    }

    const list = registry.copies_list orelse return refused("This site has no copies");
    const dot = std.mem.indexOfScalar(u8, list, '.').?;
    const words = [_][]const u8{ list[0..dot], list[dot + 1 ..] };
    const listed = try run_words(project, arena, device, &words);

    if (listed.code != 0) {
        return listed;
    }

    const parsed = std.json.parseFromSliceLeaky(Copies, arena, listed.out, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return refused("The copies could not be read");
    const copy = copy_named(parsed.environments, args[1]) orelse {
        return refused("No environment, branch or alias of that name");
    };

    if (copy.current) {
        return run_words(project, arena, device, args[2..]);
    }

    if (project.binary.len == 0 or project.db_path.len == 0) {
        return refused("Copies cannot be reached from here");
    }

    return run_copy(project, arena, device.token.id, copy.name, args[2..]);
}

fn refused(text: []const u8) error{OutOfMemory}!Answer {
    std.debug.assert(text.len > 0);

    return .{
        .code = 1,
        .out = "",
        .err = text,
    };
}

const copy_output_bytes_max: u32 = 16 << 20;

fn run_copy(
    project: *const Project,
    arena: std.mem.Allocator,
    device_id: []const u8,
    copy: []const u8,
    args: []const []const u8,
) error{OutOfMemory}!Answer {
    std.debug.assert(device_id.len > 0);
    std.debug.assert(copy.len > 0);

    const head = [_][]const u8{
        project.binary, "--db",     project.db_path, "--env",
        copy,           "--device", device_id,
    };
    const argv = try std.mem.concat(arena, []const u8, &.{ &head, args });
    const ran = std.process.run(arena, project.io, .{
        .argv = argv,
        .cwd = .{
            .path = project.folder,
        },
        .stdout_limit = .limited(copy_output_bytes_max),
        .stderr_limit = .limited(copy_output_bytes_max),
    }) catch return refused("The copy could not be reached");
    const code: u8 = switch (ran.term) {
        .exited => |exited| exited,
        else => 1,
    };

    return .{
        .code = code,
        .out = ran.stdout,
        .err = ran.stderr,
    };
}

/// The command run by the Publr at `address` with the token this machine keeps for it, or by
/// its copy `env`: its exit code, its output written to `out` and its errors to stderr.
pub fn forward(
    init: std.process.Init,
    address: []const u8,
    args: []const []const u8,
    env: ?[]const u8,
    out: *std.Io.Writer,
) !u8 {
    std.debug.assert(address.len > 0);
    std.debug.assert(args.len > 0);

    const site = try credentials.find(init, address) orelse {
        std.debug.print("publr: not signed in to {s}; run \"publr login {s}\"\n", .{
            address,
            address,
        });
        return 1;
    };
    const target = if (env) |name|
        try copy_address(init, site, name) orelse return 1
    else
        site.address;
    const answer = try send(init, site, target, args) orelse return 1;

    try out.writeAll(answer.out);
    std.debug.print("{s}", .{answer.err});

    return answer.code;
}

/// One copy as `environments list` and `open` answer it: what `--env` needs.
pub const Copy = struct {
    name: []const u8,
    aliases: []const []const u8 = &.{},
    address: []const u8 = "",
    current: bool = false,
};
pub const Copies = struct {
    environments: []const Copy,
};

/// The copy called `name`, by its slug or an alias; null when none is.
pub fn copy_named(copies: []const Copy, name: []const u8) ?Copy {
    std.debug.assert(name.len > 0);

    for (copies) |copy| {
        if (std.mem.eql(u8, copy.name, name)) {
            return copy;
        }

        for (copy.aliases) |alias| {
            if (std.mem.eql(u8, alias, name)) {
                return copy;
            }
        }
    }

    return null;
}

/// Where `site`'s copy `name` answers, started if it was stopped; null, having said why, when
/// it cannot be reached.
fn copy_address(init: std.process.Init, site: credentials.Site, name: []const u8) !?[]const u8 {
    std.debug.assert(name.len > 0);

    const arena = init.arena.allocator();
    const words = [_][]const u8{ "environments", "list" };
    const listed = try send(init, site, site.address, &words) orelse return null;
    const parse: std.json.ParseOptions = .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    };
    const parsed = std.json.parseFromSliceLeaky(Copies, arena, listed.out, parse) catch {
        std.debug.print("publr: {s} keeps no environments or branches here\n{s}", .{
            site.address,
            listed.err,
        });
        return null;
    };
    const copy = copy_named(parsed.environments, name) orelse {
        std.debug.print("publr --env: no environment, branch or alias {s}; " ++
            "`publr environments list` names them\n", .{name});
        return null;
    };

    if (copy.address.len > 0) {
        return copy.address;
    }

    const open = [_][]const u8{ "environments", "open", "--name", copy.name };
    const opened = try send(init, site, site.address, &open) orelse return null;
    const started = std.json.parseFromSliceLeaky(Copy, arena, opened.out, parse) catch null;

    if (started == null or started.?.address.len == 0) {
        std.debug.print("publr --env: {s} could not be started\n{s}", .{ name, opened.err });
        return null;
    }

    return started.?.address;
}

/// The command posted to `/api/cli` at `target` with `site`'s token; null, having said why,
/// when it was not run.
fn send(
    init: std.process.Init,
    site: credentials.Site,
    target: []const u8,
    args: []const []const u8,
) !?Answer {
    std.debug.assert(target.len > 0);
    std.debug.assert(args.len > 0);

    const arena = init.arena.allocator();
    const payload = try std.json.Stringify.valueAlloc(arena, Envelope{
        .args = args,
    }, .{});
    const reply = try post(init.io, arena, .{
        .url = try std.fmt.allocPrint(arena, "{s}{s}", .{ target, route }),
        .payload = payload,
        .token = site.token,
    });

    if (reply.status == .unauthorized) {
        std.debug.print("publr: {s} no longer accepts this device; run \"publr login {s}\"\n", .{
            target,
            site.address,
        });
        return null;
    }

    if (reply.status != .ok) {
        std.debug.print("publr: {s} answered {d}\n", .{ target, @intFromEnum(reply.status) });
        return null;
    }

    return try std.json.parseFromSliceLeaky(Answer, arena, reply.body, .{
        .ignore_unknown_fields = true,
    });
}

pub const Post = struct {
    url: []const u8,
    payload: []const u8,
    token: ?[]const u8 = null,
};
pub const Reply = struct {
    status: std.http.Status,
    body: []const u8,
};

/// A JSON body posted to `url`, with a device's token when there is one.
pub fn post(io: std.Io, arena: std.mem.Allocator, request: Post) !Reply {
    std.debug.assert(request.url.len > 0);
    std.debug.assert(request.payload.len > 0);

    var body: std.Io.Writer.Allocating = .init(arena);
    var client: std.http.Client = .{
        .allocator = arena,
        .io = io,
    };
    defer client.deinit();

    const bearer = if (request.token) |token|
        try std.fmt.allocPrint(arena, "Bearer {s}", .{token})
    else
        "";
    const authorization: []const std.http.Header = if (request.token != null)
        &.{.{
            .name = "Authorization",
            .value = bearer,
        }}
    else
        &.{};
    const result = try client.fetch(.{
        .location = .{
            .url = request.url,
        },
        .method = .POST,
        .payload = request.payload,
        .keep_alive = false,
        .headers = .{
            .content_type = .{
                .override = "application/json",
            },
        },
        .extra_headers = authorization,
        .response_writer = &body.writer,
    });

    return .{
        .status = result.status,
        .body = body.written(),
    };
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

/// Whether `host:port` speaks plain HTTP and no TLS. Some TLS servers (Cloudflare, nginx)
/// answer plain HTTP on their TLS port with an HTTP 400, so an HTTP answer alone is not
/// enough: a server that also answers a TLS record with one speaks TLS. A TLS server
/// refuses plain bytes at once and a plain one answers the TLS probe with an HTTP error,
/// so no probe waits long.
fn plain_http(io: std.Io, host: []const u8, port: u16) bool {
    std.debug.assert(port > 0);

    const answer = probe(io, host, port, "HEAD / HTTP/1.0\r\n\r\n", 5) orelse return false;

    if (!std.mem.eql(u8, answer.slice(), "HTTP/")) {
        return false;
    }

    // A ClientHello record too short to be one: a TLS server answers with an alert (0x15).
    // The blank line after it ends the bytes as an HTTP request, so a plain server answers
    // instead of waiting for more.
    const hello = "\x16\x03\x01\x00\x04\x01\x00\x00\x00\r\n\r\n";
    const tls = probe(io, host, port, hello, 1) orelse return true;
    const record = tls.slice()[0];

    return record != 0x15 and record != 0x16;
}

const Head = struct {
    bytes: [8]u8,
    len: u32,

    fn slice(head: *const Head) []const u8 {
        return head.bytes[0..head.len];
    }
};

/// The first `len` bytes `host:port` answers to `request` on a fresh connection, or null
/// when it cannot be reached or closes first.
fn probe(io: std.Io, host: []const u8, port: u16, request: []const u8, len: u32) ?Head {
    std.debug.assert(len > 0);
    std.debug.assert(len <= 8);

    const name = std.Io.net.HostName.init(host) catch return null;
    const stream = name.connect(io, port, .{
        .mode = .stream,
    }) catch return null;
    defer stream.close(io);

    var write_buffer: [64]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);

    writer.interface.writeAll(request) catch return null;
    writer.interface.flush() catch return null;

    var read_buffer: [64]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    const answer = reader.interface.peek(len) catch return null;

    var head: Head = .{
        .bytes = undefined,
        .len = len,
    };
    @memcpy(head.bytes[0..len], answer);

    return head;
}
