//! `publr update-run`: one update, in a process of its own beside the server, so the server
//! keeps answering while a release downloads. It fetches the release for this machine, checks
//! it against the checksums Publr signed, rehearses it on a copy of the database, swaps the
//! binary, and asks the server to restart in place. Every step goes into the state file.
//!
//!   publr update-run --to 0.4.0        update to that release
//!   publr update-run --rollback 0.3.2  go back to the binary kept from that release
//!   publr update-run --auto patch      the newest patch of this minor, if there is one

const std = @import("std");
const release = @import("../../model/release.zig");
const db = @import("../../lib/db.zig");
const report = @import("../../lib/report.zig");
const state_module = @import("state.zig");
const fetch = @import("fetch.zig");
const operator = @import("../operator.zig");
const backup = @import("../gate/backup.zig");

const version = @import("../../publr.zig").version;

const Run = struct {
    init: std.process.Init,
    db_path: []const u8,
    /// This binary, where it is installed; the swap happens beside it.
    executable: []const u8,
    work_dir: []const u8,
    target: []const u8,
    started_ms: i64,

    fn arena(context: *Run) std.mem.Allocator {
        return context.init.arena.allocator();
    }

    fn step(context: *Run, name: []const u8, message: []const u8) void {
        std.debug.assert(name.len > 0);

        const found = state_module.read(context.init.io, context.arena(), context.db_path);
        const previous = found.previous;

        state_module.write(context.init.io, context.arena(), context.db_path, .{
            .step = name,
            .target = context.target,
            .message = message,
            .previous = previous,
            .started_ms = context.started_ms,
        }) catch |err| std.log.warn("update state: {t}", .{err});
        std.debug.print("publr update: {s} {s}\n", .{ name, message });
    }

    fn fail(context: *Run, comptime format: []const u8, args: anytype) u8 {
        const message = std.fmt.allocPrint(context.arena(), format, args) catch "out of memory";

        context.step("failed", message);

        return 1;
    }
};

pub fn run(init: std.process.Init, db_path: []const u8, args: []const []const u8) !u8 {
    std.debug.assert(db_path.len > 0);
    std.debug.assert(version.len > 0);

    if (args.len != 2) {
        report.err("publr update-run: --to <version>, --rollback <version> or --auto patch", .{});
        return 2;
    }

    const arena = init.arena.allocator();
    var context: Run = .{
        .init = init,
        .db_path = db_path,
        .executable = try std.process.executablePathAlloc(init.io, arena),
        .work_dir = try absolute(init, try state_module.updates_dir(arena, db_path)),
        .target = args[1],
        .started_ms = @import("../../sdk.zig").context.wall_clock_ms(init.io),
    };

    const action = if (std.mem.eql(u8, args[0], "--to"))
        &apply
    else if (std.mem.eql(u8, args[0], "--rollback"))
        &rollback
    else if (std.mem.eql(u8, args[0], "--auto") and std.mem.eql(u8, args[1], "patch"))
        &auto_patch
    else
        return 2;

    return action(&context) catch |err| context.fail("stopped: {t}", .{err});
}

fn absolute(init: std.process.Init, path: []const u8) ![]const u8 {
    std.debug.assert(path.len > 0);

    const cwd = std.Io.Dir.cwd();

    try cwd.createDirPath(init.io, path);

    return cwd.realPathFileAlloc(init.io, path, init.arena.allocator());
}

fn apply(context: *Run) !u8 {
    std.debug.assert(context.target.len > 0);

    if (!release.newer(version, context.target)) {
        return context.fail("{s} is not newer than {s}", .{ context.target, version });
    }

    const arena = context.arena();
    const folder = try std.fs.path.join(arena, &.{ context.work_dir, context.target });
    const binary = try std.fs.path.join(arena, &.{ folder, release.asset_name() });

    context.step("downloading", release.asset_name());
    const source = fetch.Source.of(context.init.environ_map);

    fetch.release_files(context.init.io, arena, source, context.target, folder) catch |err|
        return context.fail("could not download {s}: {t}", .{ context.target, err });

    context.step("verifying", "the signed checksums");

    if (fetch.verified(context.init.io, arena, folder)) |why| {
        return context.fail("{s} is not the release Publr signed: {s}", .{ context.target, why });
    }

    context.step("rehearsing", "on a copy of the database");

    if (try rehearse(context, binary)) |why| {
        return context.fail("{s} refused a copy of this site: {s}", .{ context.target, why });
    }

    return swap_and_restart(context, binary, null);
}

/// The binary kept from the release before put back. If that release cannot run on the
/// data as it is (this one's migration was one-way), the backup taken before this update
/// goes back too, at the restart.
fn rollback(context: *Run) !u8 {
    std.debug.assert(context.target.len > 0);

    const arena = context.arena();
    const previous = try std.fmt.allocPrint(arena, "{s}.previous", .{context.executable});

    std.Io.Dir.cwd().access(context.init.io, previous, .{}) catch
        return context.fail("no release is kept to go back to", .{});

    context.step("rehearsing", "the release before on a copy of the database");

    const refused = try rehearse(context, previous);
    const restore = if (refused != null) try backup_before(context) else null;

    if (refused != null and restore == null) {
        return context.fail("{s} cannot run on this data and no backup is kept", .{context.target});
    }

    return swap_and_restart(context, previous, restore);
}

/// The newest patch of this minor, when one is newer: what `serve --auto-update patch` runs
/// once a day.
fn auto_patch(context: *Run) !u8 {
    std.debug.assert(version.len > 0);

    const arena = context.arena();
    const source = fetch.Source.of(context.init.environ_map);
    const releases = fetch.releases(context.init.io, arena, source) orelse return 0;

    for (releases) |candidate| {
        if (candidate.kind == .patch) {
            context.target = candidate.version;
            return apply(context);
        }
    }

    return 0;
}

/// The release at `binary` opened on a copy of this database, in a folder of its own: the
/// gate runs there, migrations and probes included. Null when it opens; else what it said.
fn rehearse(context: *Run, binary: []const u8) !?[]const u8 {
    std.debug.assert(binary.len > 0);

    const arena = context.arena();
    const folder = try std.fs.path.join(arena, &.{ context.work_dir, "rehearsal" });
    const copy = try std.fs.path.join(arena, &.{ folder, "data", "publr.db" });
    const cwd = std.Io.Dir.cwd();

    try cwd.deleteTree(context.init.io, folder);
    try cwd.createDirPath(context.init.io, std.fs.path.dirname(copy).?);
    defer cwd.deleteTree(context.init.io, folder) catch |err| {
        std.log.warn("removing the rehearsal: {t}", .{err});
    };

    try copy_database(context, copy);

    const opened = try std.process.run(arena, context.init.io, .{
        .argv = &.{ binary, "--db", copy, "--as-admin", "heartbeat", "check" },
        .cwd = .{
            .path = folder,
        },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });

    if (opened.term != .exited or opened.term.exited != 0) {
        return try errors_of(arena, opened.stderr);
    }

    return null;
}

/// What a refusing release said, its error lines only, one after another.
fn errors_of(arena: std.mem.Allocator, stderr: []const u8) ![]const u8 {
    std.debug.assert(stderr.len <= 1 << 20);

    var said: std.ArrayList(u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, stderr, '\n');

    while (lines.next()) |line| {
        const marker = "ERROR: ";

        if (!std.mem.startsWith(u8, line, marker) or std.mem.endsWith(u8, line, "Refused")) {
            continue;
        }

        const text = std.mem.trim(u8, line[marker.len..], " ");

        try said.print(arena, "{s}{s}", .{ if (said.items.len > 0) "; " else "", text });
    }

    return if (said.items.len > 0) said.items else std.mem.trim(u8, stderr, " \n");
}

fn copy_database(context: *Run, path: []const u8) !void {
    std.debug.assert(path.len > 0);

    const arena = context.arena();
    var runtime = try db.Runtime.init(.{});
    defer runtime.deinit();
    var connection = try db.open(&runtime, try arena.dupeZ(u8, context.db_path));
    defer connection.close();

    try db.copy_to(&connection, path);
}

/// `binary` put where this one is, this one kept beside it, the marker left for the next
/// start, and the server asked to restart; with no server, the next `serve` starts it.
fn swap_and_restart(context: *Run, binary: []const u8, restore: ?[]const u8) !u8 {
    std.debug.assert(binary.len > 0);

    const arena = context.arena();
    const io = context.init.io;
    const cwd = std.Io.Dir.cwd();
    const rolling_back = restore != null or std.mem.endsWith(u8, binary, ".previous");
    const kept = try std.fmt.allocPrint(arena, "{s}.{s}", .{
        context.executable,
        if (rolling_back) "rolled-back" else "previous",
    });
    const next = try std.fmt.allocPrint(arena, "{s}.next", .{context.executable});

    context.step("swapping", context.executable);
    cwd.copyFile(binary, cwd, next, io, .{
        .permissions = .executable_file,
    }) catch |err|
        return context.fail("cannot write beside {s} ({t}): update as the user who owns it", .{
            context.executable,
            err,
        });
    try cwd.rename(context.executable, cwd, kept, io);
    try cwd.rename(next, cwd, context.executable, io);

    // Back on the release before: it is the one running now, not one kept to go back to.
    if (rolling_back) {
        cwd.deleteFile(io, binary) catch |err| std.log.warn("removing {s}: {t}", .{ binary, err });
    }

    try state_module.write_marker(io, arena, context.db_path, .{
        .to = context.target,
        .previous_binary = kept,
        .previous_version = version,
        .restore = restore,
    });
    try state_module.write(io, arena, context.db_path, .{
        .step = "restarting",
        .target = context.target,
        .message = "",
        .previous = if (rolling_back) null else version,
        .started_ms = context.started_ms,
    });

    const session = try operator.find(io, arena, context.db_path) orelse {
        context.step("done", "installed; the next `publr serve` starts it");
        return 0;
    };

    _ = operator.post(io, arena, session, "/_publr/restart", "{}") catch |err|
        return context.fail("the server did not restart: {t}", .{err});

    return 0;
}

/// The newest backup taken by the update to this release: what a one-way step back restores.
fn backup_before(context: *Run) !?[]const u8 {
    std.debug.assert(version.len > 0);

    const arena = context.arena();
    const site = try backup.Site.of(context.init.io, arena, context.db_path, null);

    for (try backup.list(site, arena)) |entry| {
        if (std.mem.eql(u8, entry.about.to, version)) {
            return entry.name;
        }
    }

    return null;
}
