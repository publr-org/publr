//! A site packed for a clone in a process of its own (`publr clone-pack-run`), never in the
//! server: the server's SQLite has a fixed memory that a large database's copy outgrows, and
//! a second SQLite set up and shut down in the same process would close the server's under
//! it. The server starts it and answers at once, so the site never stops answering while it
//! packs. The process says how far it is in `<out>.progress` (ten-thousandths, rewritten
//! four times a second) and, when it ends, what it made in `<out>.made` or why not in
//! `<out>.failed`. The server keeps its id in `<out>.pid`, to reap it and to stop it when
//! the same person asks again.
const std = @import("std");
const backup = @import("../gate/backup.zig");
const bundle = @import("../bundle.zig");

pub const command = "clone-pack-run";
const side_bytes_max: u32 = 64 << 10;
const watch_ms: u32 = 250;
/// How far through the pack each stage ends, in ten-thousandths: the archive, compressed,
/// takes most of the time (1 s copying, 1 s clearing, 10 s archiving a 207 MB database).
const copied_at: u32 = 1000;
const cleared_at: u32 = 1500;
const whole: u32 = 10_000;

const progress_suffix = ".progress";
const made_suffix = ".made";
const failed_suffix = ".failed";
const pid_suffix = ".pid";
const sides = [_][]const u8{ progress_suffix, made_suffix, failed_suffix, pid_suffix };

/// What the packing process made, as it says it.
pub const Made = struct {
    bytes: u64,
    publr: []const u8,
    name: []const u8,
    parts: bundle.Parts = .{},
};

pub const Asked = struct {
    db_path: []const u8,
    /// The folder `serve` runs in; empty: the database's own project folder.
    folder: []const u8 = "",
    out: []const u8,
    keep_user: []const u8,
    media: bool = true,
};

/// Where a pack is, as the server reads it from the files beside the bundle.
pub const State = union(enum) {
    /// None was started, or what it made was taken.
    none,
    /// How far, in ten-thousandths.
    packing: u32,
    made: Made,
    failed: []const u8,
};

/// The server's side: the pack started in another process, without waiting for it; one
/// still running for the same bundle is stopped first.
pub fn start(io: std.Io, arena: std.mem.Allocator, asked: Asked) !void {
    std.debug.assert(asked.out.len > 0);
    std.debug.assert(asked.keep_user.len > 0);

    try stop(io, arena, asked.out);
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(asked.out) orelse ".");

    const binary = try std.process.executablePathAlloc(io, arena);
    var argv: std.ArrayList([]const u8) = .empty;

    try argv.appendSlice(arena, &.{
        binary,    "--db",                             asked.db_path, command,
        "--out",   asked.out,                          "--keep-user", asked.keep_user,
        "--media", if (asked.media) "all" else "none",
    });

    if (asked.folder.len > 0) {
        try argv.appendSlice(arena, &.{ "--folder", asked.folder });
    }

    const child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    const pid = child.id orelse return error.NotStarted;

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try side(arena, asked.out, pid_suffix),
        .data = try std.fmt.allocPrint(arena, "{d}", .{pid}),
    });
}

/// The server's side: where the pack for `out` is. A process that ended without saying
/// what it made failed; its own words are in the site's log.
pub fn state(io: std.Io, arena: std.mem.Allocator, out: []const u8) !State {
    std.debug.assert(out.len > 0);

    const pid = try pid_of(io, arena, out) orelse return .none;
    // Read before the files: a process that ended has said all it will.
    const ended = !running(pid);

    if (try read_side(io, arena, out, made_suffix)) |text| {
        return .{
            .made = try std.json.parseFromSliceLeaky(Made, arena, text, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            }),
        };
    }

    if (try read_side(io, arena, out, failed_suffix)) |text| {
        return .{
            .failed = text,
        };
    }

    if (ended) {
        return .{
            .failed = "the packing process stopped",
        };
    }

    const text = try read_side(io, arena, out, progress_suffix) orelse "0";
    const through = std.fmt.parseInt(u32, std.mem.trim(u8, text, " \n"), 10) catch 0;

    return .{
        .packing = @min(through, whole - 1),
    };
}

/// The server's side: a running pack for `out` stopped, and what it left removed.
pub fn stop(io: std.Io, arena: std.mem.Allocator, out: []const u8) !void {
    std.debug.assert(out.len > 0);

    if (try pid_of(io, arena, out)) |pid| {
        // Only a child of this server is still running here; an id left by an earlier
        // server is never signalled.
        if (running(pid)) {
            std.posix.kill(pid, .KILL) catch |err| {
                std.log.warn("clone: stopping the packing process: {t}", .{err});
            };

            var status: c_int = 0;

            _ = std.c.waitpid(pid, &status, 0);
        }
    }

    try forget(io, arena, out);
    try remove_if_there(io, try std.fmt.allocPrint(arena, "{s}{s}", .{
        out,
        bundle.snapshot_suffix,
    }));
}

/// The server's side: the files beside the bundle removed, once it was taken.
pub fn forget(io: std.Io, arena: std.mem.Allocator, out: []const u8) !void {
    std.debug.assert(out.len > 0);

    for (sides) |suffix| {
        try remove_if_there(io, try side(arena, out, suffix));
    }
}

/// Whether the server's child `pid` is still running; one that ended is reaped.
fn running(pid: std.posix.pid_t) bool {
    std.debug.assert(pid > 0);

    var status: c_int = 0;

    return std.c.waitpid(pid, &status, std.c.W.NOHANG) == 0;
}

fn pid_of(io: std.Io, arena: std.mem.Allocator, out: []const u8) !?std.posix.pid_t {
    std.debug.assert(out.len > 0);

    const text = try read_side(io, arena, out, pid_suffix) orelse return null;
    const pid = std.fmt.parseInt(std.posix.pid_t, text, 10) catch return null;

    return if (pid > 0) pid else null;
}

fn side(arena: std.mem.Allocator, out: []const u8, suffix: []const u8) ![]const u8 {
    std.debug.assert(suffix.len > 0);

    return std.fmt.allocPrint(arena, "{s}{s}", .{ out, suffix });
}

fn read_side(io: std.Io, arena: std.mem.Allocator, out: []const u8, suffix: []const u8) !?[]u8 {
    std.debug.assert(out.len > 0);

    const path = try side(arena, out, suffix);
    const limit: std.Io.Limit = .limited(side_bytes_max);

    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, limit) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

/// Written whole, then moved into place: a reader never sees half of it.
fn write_side(
    io: std.Io,
    arena: std.mem.Allocator,
    out: []const u8,
    suffix: []const u8,
    data: []const u8,
) !void {
    std.debug.assert(suffix.len > 0);

    const path = try side(arena, out, suffix);
    const unfinished = try std.fmt.allocPrint(arena, "{s}.tmp", .{path});
    const cwd = std.Io.Dir.cwd();

    try cwd.writeFile(io, .{
        .sub_path = unfinished,
        .data = data,
    });
    try cwd.rename(unfinished, cwd, path, io);
}

fn remove_if_there(io: std.Io, path: []const u8) !void {
    std.debug.assert(path.len > 0);

    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

/// `publr clone-pack-run`: the packing process itself.
pub fn run(
    init: std.process.Init,
    out: *std.Io.Writer,
    db_path: []const u8,
    args: []const []const u8,
) !u8 {
    std.debug.assert(args.len <= 128);
    std.debug.assert(db_path.len > 0);

    var asked = parse(args) orelse {
        std.debug.print("usage: publr --db <db> {s} --out <path> --keep-user <id> " ++
            "[--media all|none] [--folder <path>]\n", .{command});
        return 2;
    };
    asked.db_path = db_path;

    const arena = init.arena.allocator();
    const made = packed_here(init, arena, asked) catch |err| {
        std.log.err("clone: packing failed: {t}", .{err});
        try write_side(init.io, arena, asked.out, failed_suffix, @errorName(err));
        return 1;
    };
    const text = try std.json.Stringify.valueAlloc(arena, made, .{});

    try write_side(init.io, arena, asked.out, made_suffix, text);
    try out.print("{s}\n", .{text});

    return 0;
}

fn packed_here(init: std.process.Init, arena: std.mem.Allocator, asked: Asked) !Made {
    std.debug.assert(asked.out.len > 0);

    const folder: ?[]const u8 = if (asked.folder.len > 0) asked.folder else null;
    const site = try backup.Site.of(init.io, arena, asked.db_path, folder);
    const name = std.fs.path.basename(site.project_dir);
    const database = try std.fs.path.join(arena, &.{ site.data_dir, site.database });
    var progress: bundle.PackProgress = .{};
    var watch: Watch = .{
        .io = init.io,
        .progress = &progress,
        .snapshot = try side(arena, asked.out, bundle.snapshot_suffix),
        .path = try side(arena, asked.out, progress_suffix),
        .database_bytes = (try std.Io.Dir.cwd().statFile(init.io, database, .{})).size,
    };

    try std.Io.Dir.cwd().createDirPath(init.io, std.fs.path.dirname(asked.out) orelse ".");

    const thread = try std.Thread.spawn(.{}, Watch.run, .{&watch});
    defer {
        watch.stopping.store(true, .release);
        thread.join();
    }

    const made = try bundle.pack_clone(site, arena, asked.out, name, .{
        .keep_user = asked.keep_user,
        .media = asked.media,
        .progress = &progress,
    });
    const stat = try std.Io.Dir.cwd().statFile(init.io, asked.out, .{});

    return .{
        .bytes = stat.size,
        .publr = made.manifest.publr,
        .name = name,
        .parts = made.parts,
    };
}

/// Says how far the pack is, four times a second, until it is told to stop.
const Watch = struct {
    io: std.Io,
    progress: *bundle.PackProgress,
    snapshot: []const u8,
    path: []const u8,
    database_bytes: u64,
    stopping: std.atomic.Value(bool) = .init(false),

    fn run(watch: *Watch) void {
        std.debug.assert(watch.path.len > 0);

        while (!watch.stopping.load(.acquire)) {
            watch.say() catch |err| {
                std.log.warn("clone: saying how far the pack is: {t}", .{err});
            };
            std.Io.sleep(watch.io, .fromMilliseconds(watch_ms), .awake) catch return;
        }
    }

    fn say(watch: *Watch) !void {
        var text: [16]u8 = undefined;
        const shown = try std.fmt.bufPrint(&text, "{d}", .{watch.through()});

        try std.Io.Dir.cwd().writeFile(watch.io, .{
            .sub_path = watch.path,
            .data = shown,
        });
    }

    fn through(watch: *Watch) u32 {
        std.debug.assert(watch.database_bytes > 0 or watch.snapshot.len > 0);

        const progress = watch.progress;
        const stage: bundle.PackProgress.Stage = @enumFromInt(progress.stage.load(.acquire));

        return switch (stage) {
            .copying => blk: {
                const stat = std.Io.Dir.cwd().statFile(watch.io, watch.snapshot, .{}) catch {
                    break :blk 0;
                };

                break :blk share(0, copied_at, stat.size, watch.database_bytes);
            },
            .clearing => cleared_at,
            .archiving => share(
                cleared_at,
                whole - 1,
                progress.done.load(.acquire),
                progress.total.load(.acquire),
            ),
            .finished => whole,
        };
    }
};

/// `done` of `total` as a place between `from` and `to`.
fn share(from: u32, to: u32, done: u64, total: u64) u32 {
    std.debug.assert(from <= to);

    if (total == 0) {
        return from;
    }

    const part: u64 = @min(done, total) * (to - from) / total;

    return from + @as(u32, @intCast(part));
}

fn parse(args: []const []const u8) ?Asked {
    std.debug.assert(args.len <= 128);

    var asked: Asked = .{
        .db_path = "",
        .out = "",
        .keep_user = "",
    };
    var index: u32 = 0;

    while (index + 1 < args.len) : (index += 2) {
        const flag = args[index];
        const value = args[index + 1];

        if (std.mem.eql(u8, flag, "--out")) {
            asked.out = value;
        } else if (std.mem.eql(u8, flag, "--keep-user")) {
            asked.keep_user = value;
        } else if (std.mem.eql(u8, flag, "--media")) {
            asked.media = !std.mem.eql(u8, value, "none");
        } else if (std.mem.eql(u8, flag, "--folder")) {
            asked.folder = value;
        } else if (std.mem.eql(u8, flag, "--db")) {
            asked.db_path = value;
        } else {
            return null;
        }
    }

    const whole_line = index == args.len and asked.out.len > 0 and asked.keep_user.len > 0;

    return if (whole_line) asked else null;
}

test "the packing process reads what to pack" {
    const words = [_][]const u8{
        "--out", "/d/x.site.tar.gz", "--keep-user", "u1", "--media", "none",
    };
    const asked = parse(&words).?;

    try std.testing.expect(!asked.media);
    try std.testing.expectEqualStrings("u1", asked.keep_user);
    try std.testing.expect(parse(&.{ "--out", "/d/x" }) == null);
    try std.testing.expect(parse(&.{"--out"}) == null);
}

test "a pack's stages share the way: copying, clearing, then the archive by its bytes" {
    try std.testing.expectEqual(@as(u32, 500), share(0, copied_at, 50, 100));
    try std.testing.expectEqual(cleared_at, share(cleared_at, whole - 1, 0, 1000));
    try std.testing.expectEqual(whole - 1, share(cleared_at, whole - 1, 2000, 1000));
    try std.testing.expectEqual(@as(u32, 0), share(0, copied_at, 10, 0));
}
