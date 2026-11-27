//! `publr queue-run`: the queued work of the project `serve` runs (event hooks, jobs), in a
//! process of its own, so a slow hook or job never delays a request. `serve` starts it and
//! starts it again when it ends; it ends when `serve` does.
const std = @import("std");
const sdk = @import("../sdk.zig");
const server = @import("../server.zig");
const queued_jobs = @import("queued_jobs.zig");
const store = @import("../store.zig");
const spawn = @import("../lib/spawn.zig");

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
        .call_scratch = &application.call_scratch,
        .plugin_memory = &application.plugin_memory,
        .definitions = &application.definitions,
        .languages = &application.languages,
    };

    project.outside = try outside_of(init.arena.allocator(), args);
    project.on_copy = @import("project.zig").copy_of_environment();

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

        queued_jobs.tick(&project, init.gpa, &clock, project.now_ms());

        try std.Io.sleep(init.io, .fromMilliseconds(pause_ms), .awake);
    }

    return 0;
}

/// Where its plugins' outside calls may go: the rule `serve` follows, from the origins
/// `serve` passes (`--site-url`, `--admin-url`, and `--started-url` while the site answers
/// away from the `--url` it started at); the worker serves nothing itself.
pub fn outside_of(
    arena: std.mem.Allocator,
    args: []const []const u8,
) error{OutOfMemory}!@import("../model/outside.zig").Rule {
    std.debug.assert(args.len <= 64);

    return @import("project.zig").outside_of(arena, .{
        .site = option_of(args, "--site-url"),
        .admin = option_of(args, "--admin-url"),
        .started = option_of(args, "--started-url"),
    });
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

    std.debug.assert(@backingInt(std.posix.SIG.TERM) != @backingInt(std.posix.SIG.INT));
}

/// How `serve` starts the worker: `executable` on its database, told the origins its rule
/// follows (`outside_of`); `--started-url` only while the site answers away from it. As C
/// strings, the last one null, as `posix_spawn` takes them (`Keeper`).
pub fn argv_of(
    arena: std.mem.Allocator,
    executable: []const u8,
    db_path: []const u8,
    origins: @import("../model/outside.zig").Origins,
) error{OutOfMemory}![:null]?[*:0]const u8 {
    std.debug.assert(executable.len > 0);
    std.debug.assert(db_path.len > 0);

    const moved = origins.started.len > 0 and !std.mem.eql(u8, origins.started, origins.site);
    const all = [_][]const u8{
        executable,
        "--db",
        db_path,
        "queue-run",
        "--site-url",
        origins.site,
        "--admin-url",
        origins.admin,
        "--started-url",
        origins.started,
    };
    const words = if (moved) all[0..] else all[0..8];
    const argv = try arena.allocSentinel(?[*:0]const u8, words.len, null);

    for (words, argv) |word, *slot| {
        slot.* = try arena.dupeSentinel(u8, word, 0);
    }

    return argv;
}

/// The worker `serve` keeps running beside it, started with `posix_spawn` (`lib/spawn.zig`)
/// rather than a copy of `serve`: in a small VM a copy would be booked for all of `serve`'s
/// reserved memory and refused.
pub const Keeper = struct {
    /// `publr --db <path> queue-run ...`, as C strings, the last one null.
    argv: [*:null]const ?[*:0]const u8,
    pid: ?std.c.pid_t = null,
    /// When it may be started again after ending: never more than once a second.
    next_start_ms: i64 = 0,

    /// Started when not running, at most once a second; a worker that ended is reaped.
    pub fn tick(keeper: *Keeper, now_ms: i64) void {
        std.debug.assert(keeper.argv[0] != null);
        std.debug.assert(now_ms >= 0);

        if (keeper.pid) |pid| {
            if (!spawn.ended(pid)) {
                return;
            }

            std.log.warn("worker: ended; starting it again", .{});
            keeper.pid = null;
        }

        if (now_ms < keeper.next_start_ms) {
            return;
        }

        keeper.next_start_ms = now_ms + 1000;
        keeper.pid = spawn.start(keeper.argv) catch |err| blk: {
            std.log.warn("worker: not started: {t}", .{err});
            break :blk null;
        };
    }

    pub fn stop(keeper: *Keeper) void {
        std.debug.assert(keeper.argv[0] != null);

        if (keeper.pid) |pid| {
            spawn.stop(pid);
        }

        keeper.pid = null;
    }

    /// Stopped, to be started again with `argv` at the next tick: the site moved.
    pub fn restart(keeper: *Keeper, argv: [*:null]const ?[*:0]const u8) void {
        std.debug.assert(argv[0] != null);

        keeper.stop();
        keeper.argv = argv;
        keeper.next_start_ms = 0;

        std.debug.assert(keeper.pid == null);
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
    const served = try project.outside_of(arena, .{
        .site = site,
        .admin = admin,
    });

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

    const moved = try outside_of(arena, &.{
        "--site-url",
        "https://mykiosk.com",
        "--admin-url",
        "https://kiosk--admin.publr.app",
        "--started-url",
        "https://kiosk.publr.app",
    });

    try std.testing.expectEqual(@as(usize, 3), moved.own_hosts.len);
    try std.testing.expectEqualStrings("mykiosk.com", moved.own_hosts[0]);
}

test {
    _ = spawn;
}
