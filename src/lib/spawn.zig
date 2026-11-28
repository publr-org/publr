//! Starting another program without copying this one. `std.process.spawn` forks on Linux, and
//! the kernel books a fork as needing every writable page this process reserved, again: a
//! server that reserved more than half of a small VM could not start a child at all. libc's
//! `posix_spawn` starts the program without that copy (musl and glibc clone with the memory
//! shared, macOS has its own), so the child is booked only for what it reserves itself.
const std = @import("std");

/// WASI has no processes: in the browser build nothing is started, nothing runs to end or stop.
const has_processes = @import("builtin").os.tag != .wasi;

pub const Error = error{
    /// The system had no memory or no process slot to start it with.
    SystemResources,
    /// The program could not be started: missing, not executable, refused.
    SpawnFailed,
};

extern "c" fn posix_spawn(
    pid: *std.c.pid_t,
    path: [*:0]const u8,
    file_actions: ?*const anyopaque,
    attributes: ?*const anyopaque,
    argv: [*:null]const ?[*:0]const u8,
    environment: [*:null]const ?[*:0]const u8,
) c_int;

/// `argv[0]` run with `argv`, with this process's environment, standard streams and folder.
/// Its process id, to see whether it ended or to stop it.
pub fn start(argv: [*:null]const ?[*:0]const u8) Error!std.c.pid_t {
    const program = argv[0] orelse unreachable;
    var pid: std.c.pid_t = 0;

    std.debug.assert(program[0] != 0);

    if (comptime !has_processes) {
        return error.SpawnFailed;
    }

    const result = posix_spawn(&pid, program, null, null, argv, @ptrCast(std.c.environ));

    if (result != 0) {
        const code: std.c.E = @fromBackingInt(@intCast(result));

        return switch (code) {
            .NOMEM, .AGAIN => error.SystemResources,
            else => error.SpawnFailed,
        };
    }

    std.debug.assert(pid > 0);

    return pid;
}

/// Whether the process has ended; reaped, without waiting, when it has.
pub fn ended(pid: std.c.pid_t) bool {
    std.debug.assert(pid > 0);

    if (comptime !has_processes) {
        return true;
    }

    var status: c_int = 0;
    const reaped = std.c.waitpid(pid, &status, std.c.W.NOHANG);

    std.debug.assert(reaped == 0 or reaped == pid or reaped == -1);

    return reaped == pid or reaped == -1;
}

/// Asks the process to stop, and waits until it has.
pub fn stop(pid: std.c.pid_t) void {
    std.debug.assert(pid > 0);

    if (comptime !has_processes) {
        return;
    }

    var status: c_int = 0;

    _ = std.c.kill(pid, .TERM);

    const reaped = std.c.waitpid(pid, &status, 0);

    std.debug.assert(reaped == pid or reaped == -1);
}

test "a program started without a copy of this process runs, ends and is reaped" {
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "exit 0" };
    const pid = try start(&argv);
    var waited: u32 = 0;

    while (!ended(pid) and waited < 500) : (waited += 1) {
        const pause: std.c.timespec = .{
            .sec = 0,
            .nsec = 10 * std.time.ns_per_ms,
        };

        _ = std.c.nanosleep(&pause, null);
    }

    try std.testing.expect(waited < 500);
}

test "a program that is not there is refused, not started" {
    const argv = [_:null]?[*:0]const u8{"/nonexistent/publr-test-program"};
    const started = start(&argv);

    // musl reports a missing program from posix_spawn itself; a libc that reports it only
    // from the child sees the child end at once.
    if (started) |pid| {
        stop(pid);
    } else |err| {
        try std.testing.expectEqual(error.SpawnFailed, err);
    }
}
