//! While `publr serve` runs, it owns the project: a command given to the CLI is sent to it
//! and run there, through the same dispatcher, so the operation's events fire where the
//! plugins and apps live and what it changes takes effect at once. `serve` leaves its port
//! and a key beside the database (`<db>.serve`, readable by its user only, as the database
//! is); the CLI finds them there. With no server, the CLI runs the command itself.
const std = @import("std");
const http = @import("../lib/http.zig");
const cli = @import("../adapters/cli.zig");
const registry = @import("registry.zig");
const server = @import("../server.zig");
const sdk = @import("../sdk.zig");
const Project = @import("project.zig").Project;

pub const route = "/_publr/cli";
pub const key_len: u32 = 64;
const session_bytes_max: u32 = 256;

/// `build` stamps the binary the server runs (`build_stamp`): one started from an older
/// build of the file has another, and 0 when it is not known.
pub const Session = struct { port: u16, key: [key_len]u8, build: u64 = 0 };

const Envelope = struct { args: []const []const u8, password: ?[]const u8 = null };
const Answer = struct { code: u8, out: []const u8, err: []const u8 };

pub fn path_of(arena: std.mem.Allocator, db_path: []const u8) ![]const u8 {
    std.debug.assert(db_path.len > 0);

    return std.fmt.allocPrint(arena, "{s}.serve", .{db_path});
}

/// `serve`, once listening: a fresh key, written with the port beside the database.
pub fn open(io: std.Io, arena: std.mem.Allocator, db_path: []const u8, port: u16) !Session {
    std.debug.assert(port > 0);

    var secret: [key_len / 2]u8 = undefined;
    io.random(&secret);

    const session: Session = .{
        .port = port,
        .key = std.fmt.bytesToHex(secret, .lower),
        .build = build_stamp(io, arena),
    };
    const text = try std.fmt.allocPrint(arena, "{d} {s} {d}\n", .{
        port,
        &session.key,
        session.build,
    });
    var file = try std.Io.Dir.cwd().createFile(io, try path_of(arena, db_path), .{
        .permissions = .fromMode(0o600),
    });
    defer file.close(io);

    try file.writeStreamingAll(io, text);

    std.debug.assert(text.len < session_bytes_max);

    return session;
}

pub fn close(io: std.Io, arena: std.mem.Allocator, db_path: []const u8) void {
    std.debug.assert(db_path.len > 0);

    const path = path_of(arena, db_path) catch return;

    std.Io.Dir.cwd().deleteFile(io, path) catch |err| {
        std.log.warn("{s}: {t}", .{ path, err });
    };
}

/// The session a running server left, or null. One whose server no longer answers (it
/// stopped without removing it) is removed.
pub fn find(io: std.Io, arena: std.mem.Allocator, db_path: []const u8) !?Session {
    const path = try path_of(arena, db_path);
    const cwd = std.Io.Dir.cwd();
    const text = cwd.readFileAlloc(io, path, arena, .limited(session_bytes_max)) catch {
        return null;
    };
    const session = parse(text) orelse return null;

    std.debug.assert(session.port > 0);

    if (!answers(io, session.port)) {
        cwd.deleteFile(io, path) catch |err| std.log.warn("{s}: {t}", .{ path, err });
        return null;
    }

    return session;
}

fn parse(text: []const u8) ?Session {
    std.debug.assert(text.len <= session_bytes_max);

    var words = std.mem.tokenizeAny(u8, text, " \n");
    const port_text = words.next() orelse return null;
    const key = words.next() orelse return null;
    const port = std.fmt.parseInt(u16, port_text, 10) catch return null;
    const build_text = words.next() orelse "0";
    const build = std.fmt.parseInt(u64, build_text, 10) catch 0;

    if (key.len != key_len or port == 0) {
        return null;
    }

    return .{ .port = port, .key = key[0..key_len].*, .build = build };
}

/// The binary at this process's path as it is now: its file's modification time. A rebuild
/// changes it; 0 when it cannot be read.
pub fn build_stamp(io: std.Io, arena: std.mem.Allocator) u64 {
    const path = std.process.executablePathAlloc(io, arena) catch return 0;
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return 0;
    const nanoseconds = stat.mtime.nanoseconds;

    std.debug.assert(path.len > 0);
    std.debug.assert(stat.size > 0);

    return if (nanoseconds <= 0) 0 else @truncate(@as(u96, @intCast(nanoseconds)));
}

fn answers(io: std.Io, port: u16) bool {
    std.debug.assert(port > 0);

    const address = std.Io.net.IpAddress.parse("127.0.0.1", port) catch return false;
    const stream = address.connect(io, .{ .mode = .stream }) catch return false;

    stream.close(io);

    return true;
}

/// The command run by the server when one runs for this database: its exit code, its
/// output written to `out` and its errors to stderr. Null when no server runs.
pub fn forward(
    init: std.process.Init,
    db_path: []const u8,
    args: []const []const u8,
    out: *std.Io.Writer,
) !?u8 {
    std.debug.assert(db_path.len > 0);

    const arena = init.arena.allocator();
    const session = try find(init.io, arena, db_path) orelse return null;
    const envelope: Envelope = .{
        .args = try absolute_files(init, args),
        .password = init.environ_map.get("PUBLR_PASSWORD"),
    };
    const payload = try std.json.Stringify.valueAlloc(arena, envelope, .{});
    const body = try post(init.io, arena, session, route, payload);
    const answer = try std.json.parseFromSliceLeaky(Answer, arena, body, .{});

    try out.writeAll(answer.out);
    std.debug.print("{s}", .{answer.err});

    return answer.code;
}

/// `payload` posted to the running server at `path` with its key; the answer's body.
pub fn post(
    io: std.Io,
    arena: std.mem.Allocator,
    session: Session,
    path: []const u8,
    payload: []const u8,
) ![]const u8 {
    std.debug.assert(path.len > 0);
    std.debug.assert(session.port > 0);

    const url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}{s}", .{ session.port, path });
    var body: std.Io.Writer.Allocating = .init(arena);
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "X-Publr-Operator", .value = &session.key }},
        .response_writer = &body.writer,
    });

    if (result.status != .ok) {
        return error.ServerRefused;
    }

    return body.written();
}

/// Whether a request carries this run's key: only the CLI next to it has it.
pub fn authorized(request: *const http.Request, project: *const Project) bool {
    const key = project.operator_key orelse return false;
    const given = request.header("X-Publr-Operator") orelse "";

    std.debug.assert(key.len == key_len);

    return same_key(key, given);
}

/// A file named on the command line is read by the server, which may run elsewhere: it goes
/// as an absolute path.
fn absolute_files(init: std.process.Init, args: []const []const u8) ![]const []const u8 {
    const arena = init.arena.allocator();
    const copy = try arena.dupe([]const u8, args);

    std.debug.assert(copy.len == args.len);

    for (copy[0..copy.len -| 1], 0..) |arg, index| {
        if (std.mem.eql(u8, arg, "--file") and !std.fs.path.isAbsolute(copy[index + 1])) {
            const cwd = try std.Io.Dir.cwd().realPathFileAlloc(init.io, ".", arena);

            copy[index + 1] = try std.fs.path.join(arena, &.{ cwd, copy[index + 1] });
        }
    }

    return copy;
}

/// `POST /_publr/cli`: a command from the CLI next to this server, run as the CLI would run
/// it; answered with its exit code, output and errors. Only with this run's key.
pub fn handle(
    request: *http.Request,
    response: *http.Response,
    ctx: *http.Context,
) http.Error!void {
    const project = Project.of(ctx);

    if (!authorized(request, project)) {
        return response.text(.forbidden, "Forbidden");
    }

    const envelope = std.json.parseFromSliceLeaky(Envelope, ctx.arena, request.body, .{}) catch {
        return response.text(.bad_request, "Bad Request");
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
        .password_env = envelope.password,
        .sandboxed_plugins = project.sandboxed_plugins,
        .plugin_states = project.plugin_states,
        .files = project.files,
    }, envelope.args, &out.writer) catch |failure| blk: {
        err.writer.print("publr: {s}\n", .{@errorName(failure)}) catch {
            return response.text(.internal_server_error, @errorName(failure));
        };
        break :blk 1;
    };

    try response.json(.ok, Answer{ .code = code, .out = out.written(), .err = err.written() });
}

fn same_key(key: []const u8, given: []const u8) bool {
    std.debug.assert(key.len == key_len);

    if (given.len != key_len) {
        return false;
    }

    return std.crypto.timing_safe.eql([key_len]u8, key[0..key_len].*, given[0..key_len].*);
}

/// Runs commands: in the server when one runs for this database, else in this process,
/// which opens the database once, on its first command.
pub const Commands = struct {
    init: std.process.Init,
    db_path: [:0]const u8,
    local: ?*server.Server = null,
    arena_bytes: []u8 = &.{},

    pub fn run(commands: *Commands, args: []const []const u8, out: *std.Io.Writer) !u8 {
        std.debug.assert(args.len > 0);

        if (try forward(commands.init, commands.db_path, args, out)) |code| {
            return code;
        }

        const application = try commands.open_local();
        var fixed = std.heap.FixedBufferAllocator.init(commands.arena_bytes);

        std.debug.assert(commands.arena_bytes.len == server.request_arena_bytes);

        return cli.CLI(registry.SDK).run(.{
            .db = &application.connection,
            .io = commands.init.io,
            .arena = fixed.allocator(),
            .auth = &application.auth,
            .now_ms = sdk.context.wall_clock_ms(commands.init.io),
            .password_env = commands.init.environ_map.get("PUBLR_PASSWORD"),
            .sandboxed_plugins = application.sandboxed(),
            .plugin_states = &application.plugin_states,
            .files = application.files_of(),
        }, args, out);
    }

    fn open_local(commands: *Commands) !*server.Server {
        if (commands.local) |application| {
            return application;
        }

        const gpa = commands.init.gpa;
        const application = try gpa.create(server.Server);
        errdefer gpa.destroy(application);

        try application.init(commands.init, commands.db_path);
        errdefer application.deinit();

        commands.arena_bytes = try gpa.alloc(u8, server.request_arena_bytes);
        commands.local = application;

        std.debug.assert(commands.local != null);

        return application;
    }

    pub fn deinit(commands: *Commands) void {
        const gpa = commands.init.gpa;

        std.debug.assert(commands.local == null or commands.arena_bytes.len > 0);

        if (commands.local) |application| {
            application.deinit();
            gpa.destroy(application);
            gpa.free(commands.arena_bytes);
        }

        commands.* = undefined;
    }
};

test "a session reads its port, key and build; one written before builds were kept has 0" {
    const key = "a" ** key_len;
    const stamped = parse("8080 " ++ key ++ " 1759740000123456789\n").?;
    const unstamped = parse("8080 " ++ key ++ "\n").?;

    try std.testing.expectEqual(@as(u64, 1759740000123456789), stamped.build);
    try std.testing.expectEqual(@as(u64, 0), unstamped.build);
    try std.testing.expect(parse("0 " ++ key ++ "\n") == null);
}
