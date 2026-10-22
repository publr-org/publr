//! `publr queue-run`: the queued work of the project `serve` runs (event hooks, jobs), in a
//! process of its own, so a slow hook or job never delays a request. `serve` starts it and
//! starts it again when it ends; it ends when `serve` does.
const std = @import("std");
const sdk = @import("../sdk.zig");
const server = @import("../server.zig");
const queued_jobs = @import("queued_jobs.zig");
const store = @import("../store.zig");

const Project = @import("project.zig").Project;

/// How long the worker sleeps between two looks at the queues.
pub const pause_ms: u32 = 200;

pub fn run(init: std.process.Init, db_path: [:0]const u8, args: []const []const u8) !u8 {
    std.debug.assert(db_path.len > 0);
    std.debug.assert(pause_ms > 0);

    default_signals();

    var application: server.Server = undefined;
    try application.init(init, db_path);
    defer application.deinit();

    var project: Project = .{
        .connection = &application.connection,
        .auth = &application.auth,
        .io = init.io,
        .sandboxed_plugins = application.sandboxed(),
        .plugin_states = &application.plugin_states,
        .files = application.files_of(),
        .scratch = &application.scratch,
        .definitions = &application.definitions,
        .languages = &application.languages,
    };

    project.outside = try outside_of(init.arena.allocator(), args);

    var clock: queued_jobs.Clock = .{};
    var loaded = try store.sandboxed_plugins.stamp(&application.connection);
    // Orphaned, a process is handed to another parent: `serve` has ended.
    const parent = std.posix.getppid();

    while (std.posix.getppid() == parent) {
        // The plugins changed in `serve` (installed, enabled, granted): loaded again here.
        const now_loaded = try store.sandboxed_plugins.stamp(&application.connection);

        if (!std.meta.eql(now_loaded, loaded)) {
            loaded = now_loaded;
            try application.sandboxed_plugins.load_all(&application.connection);
        }

        queued_jobs.tick(&project, init.gpa, &clock, sdk.context.wall_clock_ms(init.io));

        try std.Io.sleep(init.io, .fromMilliseconds(pause_ms), .awake);
    }

    return 0;
}

/// Where its plugins' outside calls may go: the rule `serve` follows, from the site's and
/// the admin's origins `serve` passes (`--site-url`, `--admin-url`); the worker serves
/// nothing itself.
pub fn outside_of(
    arena: std.mem.Allocator,
    args: []const []const u8,
) error{OutOfMemory}!@import("../model/outside.zig").Rule {
    std.debug.assert(args.len <= 64);

    return @import("project.zig").outside_of(
        arena,
        option_of(args, "--site-url"),
        option_of(args, "--admin-url"),
    );
}

/// The value after `name` in `args`; empty when it is not there.
fn option_of(args: []const []const u8, name: []const u8) []const u8 {
    std.debug.assert(name.len > 2);
    std.debug.assert(args.len <= 64);

    for (args, 0..) |arg, index| {
        if (std.mem.eql(u8, arg, name) and index + 1 < args.len) {
            return args[index + 1];
        }
    }

    return "";
}

/// Stopping takes a signal again: `serve` ignores SIGTERM and SIGINT (macOS) or blocks them
/// (Linux) to hear them through its event loop, and a child starts with both.
fn default_signals() void {
    const action: std.posix.Sigaction = .{
        .handler = .{
            .handler = std.posix.SIG.DFL,
        },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var stopping = std.posix.sigemptyset();

    std.posix.sigaddset(&stopping, .TERM);
    std.posix.sigaddset(&stopping, .INT);
    std.posix.sigaction(.TERM, &action, null);
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigprocmask(std.posix.SIG.UNBLOCK, &stopping, null);

    std.debug.assert(@intFromEnum(std.posix.SIG.TERM) != @intFromEnum(std.posix.SIG.INT));
}

/// The worker `serve` keeps running beside it.
pub const Keeper = struct {
    io: std.Io,
    argv: []const []const u8,
    child: ?std.process.Child = null,
    /// When it may be started again after ending: never more than once a second.
    next_start_ms: i64 = 0,

    /// Started when not running, at most once a second; a worker that ended is reaped.
    pub fn tick(keeper: *Keeper, now_ms: i64) void {
        std.debug.assert(keeper.argv.len > 0);
        std.debug.assert(now_ms >= 0);

        if (keeper.child) |child| {
            if (!ended(child)) {
                return;
            }

            std.log.warn("worker: ended; starting it again", .{});
            keeper.child = null;
        }

        if (now_ms < keeper.next_start_ms) {
            return;
        }

        keeper.next_start_ms = now_ms + 1000;
        keeper.child = std.process.spawn(keeper.io, .{
            .argv = keeper.argv,
            .stdin = .ignore,
            .stdout = .inherit,
            .stderr = .inherit,
        }) catch |err| blk: {
            std.log.warn("worker: not started: {t}", .{err});
            break :blk null;
        };
    }

    /// Whether the worker has ended, reaped without waiting.
    fn ended(child: std.process.Child) bool {
        const pid = child.id orelse return true;
        var status: c_int = 0;

        std.debug.assert(pid > 0);

        return std.c.waitpid(pid, &status, std.c.W.NOHANG) == pid;
    }

    pub fn stop(keeper: *Keeper) void {
        std.debug.assert(keeper.argv.len > 0);

        if (keeper.child) |*child| {
            child.kill(keeper.io);
        }

        keeper.child = null;
    }
};

test "the worker follows serve's rule: development for a plain http site, else production" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const project = @import("project.zig");
    const site = "http://127.0.0.1:8080";
    const admin = "http://admin.localhost:8080";
    const laptop = try outside_of(arena, &.{ "--site-url", site, "--admin-url", admin });
    const served = try project.outside_of(arena, site, admin);

    try std.testing.expectEqual(served.production, laptop.production);
    try std.testing.expect(!laptop.production);
    try std.testing.expectEqual(@as(usize, 2), laptop.own_hosts.len);
    try std.testing.expectEqualStrings("admin.localhost", laptop.own_hosts[1]);

    const public = try outside_of(arena, &.{
        "--site-url",
        "https://shop.example.com",
        "--admin-url",
        "https://admin.shop.example.com",
    });

    try std.testing.expect(public.production);
    try std.testing.expect((try outside_of(arena, &.{})).production);
}
