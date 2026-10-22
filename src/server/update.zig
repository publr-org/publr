//! Updating the Publr a site runs, from `serve`: the hook the `update` operations reach,
//! the restart in place once a new binary is swapped in, and the way back when it cannot
//! start. The work itself runs in its own process (`update/run.zig`).

const std = @import("std");
const sdk_context = @import("../sdk/context.zig");
const release = @import("../model/release.zig");
const report = @import("../lib/report.zig");
const state_module = @import("update/state.zig");
const fetch_module = @import("update/fetch.zig");
const backup = @import("gate/backup.zig");
const http = @import("../lib/http.zig");
const operator = @import("operator.zig");
const Project = @import("project.zig").Project;

pub const run = @import("update/run.zig").run;
pub const state = state_module;
pub const fetch = fetch_module;

pub const Updater = struct {
    io: std.Io,
    db_path: []const u8,
    managed: bool,
    /// `serve --auto-update patch`.
    auto: bool = false,
    /// When the next daily look for a patch is due; the first a minute after start.
    auto_due_ms: i64 = 0,
    executable: []const u8 = "",

    pub fn hook(updater: *Updater, arena: std.mem.Allocator) !sdk_context.Updater {
        std.debug.assert(updater.db_path.len > 0);
        std.debug.assert(updater.executable.len == 0);

        updater.executable = try std.process.executablePathAlloc(updater.io, arena);

        return .{
            .context = updater,
            .managed = updater.managed,
            .start = start,
            .status = status,
            .releases = releases,
        };
    }

    fn of(context: *anyopaque) *Updater {
        const updater: *Updater = @ptrCast(@alignCast(context));

        std.debug.assert(updater.db_path.len > 0);

        return updater;
    }

    fn start(
        context: *anyopaque,
        action: sdk_context.UpdateAction,
        version: []const u8,
    ) ?[]const u8 {
        const updater = of(context);

        std.debug.assert(version.len > 0);

        if (updater.managed) {
            return "Publr Cloud keeps this site's Publr up to date";
        }

        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const now_ms = @import("../sdk.zig").context.wall_clock_ms(updater.io);

        if (state_module.read(updater.io, arena, updater.db_path).running(now_ms)) {
            return "An update is already on its way";
        }

        const flag = switch (action) {
            .apply => "--to",
            .rollback => "--rollback",
        };

        updater.spawn(arena, flag, version) catch |err| {
            std.log.warn("update {s} {s}: {t}", .{ flag, version, err });
            return "The update could not be started";
        };

        return null;
    }

    /// Once a day, the newest patch of this minor, when there is one: the process looks,
    /// and updates only if it finds one.
    pub fn tick(updater: *Updater, now_ms: i64) void {
        std.debug.assert(updater.auto);
        std.debug.assert(now_ms > 0);

        if (updater.auto_due_ms == 0) {
            updater.auto_due_ms = now_ms + std.time.ms_per_min;
            return;
        }

        if (now_ms < updater.auto_due_ms or updater.managed) {
            return;
        }

        updater.auto_due_ms = now_ms + std.time.ms_per_day;

        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_state.deinit();

        const found = state_module.read(updater.io, arena_state.allocator(), updater.db_path);

        if (found.running(now_ms)) {
            return;
        }

        updater.spawn(arena_state.allocator(), "--auto", "patch") catch |err| {
            std.log.warn("auto-update: {t}", .{err});
        };
    }

    fn spawn(
        updater: *Updater,
        arena: std.mem.Allocator,
        flag: []const u8,
        version: []const u8,
    ) !void {
        std.debug.assert(flag.len > 0);
        std.debug.assert(updater.executable.len > 0);

        const dir = try state_module.updates_dir(arena, updater.db_path);
        const log_path = try std.fmt.allocPrint(arena, "{s}/{s}.log", .{ dir, version });
        const cwd = std.Io.Dir.cwd();

        try cwd.createDirPath(updater.io, dir);

        // A daily look for a patch says nothing until it finds one to apply; a look for
        // releases keeps what it finds apart.
        const updating = std.mem.eql(u8, flag, "--to") or std.mem.eql(u8, flag, "--rollback");

        if (updating) {
            try state_module.write(updater.io, arena, updater.db_path, .{
                .step = "starting",
                .target = version,
                .previous = state_module.read(updater.io, arena, updater.db_path).previous,
                .started_ms = @import("../sdk.zig").context.wall_clock_ms(updater.io),
            });
        }

        var log = try cwd.createFile(updater.io, log_path, .{});
        defer log.close(updater.io);

        // Not waited for: it outlives this request, and restarts this server when done.
        _ = try std.process.spawn(updater.io, .{
            .argv = &.{ updater.executable, "--db", updater.db_path, "update-run", flag, version },
            .stdin = .ignore,
            .stdout = .{
                .file = log,
            },
            .stderr = .{
                .file = log,
            },
        });
    }

    fn status(context: *anyopaque, arena: std.mem.Allocator) sdk_context.UpdateStatus {
        const updater = of(context);
        const found = state_module.read(updater.io, arena, updater.db_path);

        std.debug.assert(found.step.len > 0);

        var status_out = found.status();

        status_out.backups = backups_of(updater, arena) catch &.{};

        return status_out;
    }

    fn backups_of(updater: *Updater, arena: std.mem.Allocator) ![]const sdk_context.UpdateBackup {
        std.debug.assert(updater.db_path.len > 0);

        const site = try backup.Site.of(updater.io, arena, updater.db_path, null);
        const entries = try backup.list(site, arena);
        const out = try arena.alloc(sdk_context.UpdateBackup, entries.len);

        for (entries, out) |entry, *item| {
            item.* = .{
                .name = entry.name,
                .from = entry.about.from,
                .to = entry.about.to,
                .at_ms = entry.about.at_ms,
            };
        }

        return out;
    }

    fn releases(context: *anyopaque, arena: std.mem.Allocator) sdk_context.Releases {
        const updater = of(context);
        const now_ms = @import("../sdk.zig").context.wall_clock_ms(updater.io);
        var looked = state_module.read_looked(updater.io, arena, updater.db_path);

        std.debug.assert(updater.db_path.len > 0);

        if (looked.due(now_ms)) {
            looked.started_ms = now_ms;
            updater.look(arena, looked) catch |err| {
                std.log.warn("looking for releases: {t}", .{err});
                looked.started_ms = 0;
            };
        }

        return .{
            .releases = looked.releases,
            .looking = looked.looking(now_ms),
            .problem = looked.problem,
        };
    }

    /// `update-run --look releases` started, marked as on its way so one runs at a time.
    fn look(updater: *Updater, arena: std.mem.Allocator, looked: state_module.Looked) !void {
        std.debug.assert(looked.started_ms > 0);

        try state_module.write_looked(updater.io, arena, updater.db_path, looked);
        try updater.spawn(arena, "--look", "releases");
    }
};

pub const restart_route = "/_publr/restart";

/// `POST /_publr/restart`, from the update process next to this server once it swapped the
/// binary: the server stops at its next tick and becomes the new one (`restart`).
pub fn handle_restart(
    request: *http.Request,
    response: *http.Response,
    ctx: *http.Context,
) http.Error!void {
    const project = Project.of(ctx);

    if (!operator.authorized(request, project)) {
        return response.text(.forbidden, "Forbidden");
    }

    std.debug.assert(project.operator_key != null);

    project.restart_requested = true;
    project.stop_requested = true;

    return response.json(.ok, .{
        .restarting = true,
    });
}

/// The first start after a swap serves: the marker goes, and the update is done.
pub fn served(io: std.Io, arena: std.mem.Allocator, db_path: []const u8, version: []const u8) void {
    std.debug.assert(db_path.len > 0);

    const marker = state_module.read_marker(io, arena, db_path) orelse return;
    const back = !release.newer(marker.previous_version, version);
    const verb = if (back) "Back on" else "Updated to";
    const message = std.fmt.allocPrint(arena, "{s} {s} (from {s})", .{
        verb,
        version,
        marker.previous_version,
    }) catch "Updated";

    state_module.write(io, arena, db_path, .{
        .step = "done",
        .target = version,
        .message = message,
        .previous = if (back) null else marker.previous_version,
        .started_ms = 1,
    }) catch |err| std.log.warn("update state: {t}", .{err});
    state_module.remove_marker(io, arena, db_path) catch |err| {
        std.log.warn("update marker: {t}", .{err});
    };
    report.info("publr: {s}\n", .{message});
}

/// This start could not open the site after a swap: the binary it replaced goes back in its
/// place and runs instead, with the same arguments. Returns only when there is nothing to
/// go back to.
pub fn go_back(init: std.process.Init, db_path: []const u8, why: anyerror) void {
    std.debug.assert(db_path.len > 0);

    const arena = init.arena.allocator();
    const io = init.io;
    const marker = state_module.read_marker(io, arena, db_path) orelse return;
    const executable = std.process.executablePathAlloc(io, arena) catch return;
    const failed = std.fmt.allocPrint(arena, "{s}.failed", .{executable}) catch return;
    const cwd = std.Io.Dir.cwd();
    const message = std.fmt.allocPrint(arena, "{s} could not open this site ({t}); back on {s}", .{
        marker.to,
        why,
        marker.previous_version,
    }) catch "the new release could not start";

    report.err("publr: {s}", .{message});
    cwd.rename(executable, cwd, failed, io) catch return;
    cwd.rename(marker.previous_binary, cwd, executable, io) catch return;
    state_module.remove_marker(io, arena, db_path) catch return;
    state_module.write(io, arena, db_path, .{
        .step = "failed",
        .target = marker.to,
        .message = message,
        .started_ms = 1,
    }) catch |err| std.log.warn("update state: {t}", .{err});

    replace(init, executable);
}

/// After `serve` stopped for a restart: the backup a one-way step back needs put back, then
/// this process becomes the binary now installed, with the same arguments.
pub fn restart(init: std.process.Init, db_path: []const u8) void {
    std.debug.assert(db_path.len > 0);

    const arena = init.arena.allocator();
    const executable = std.process.executablePathAlloc(init.io, arena) catch return;

    if (state_module.read_marker(init.io, arena, db_path)) |marker| {
        if (marker.restore) |name| {
            restore(init, db_path, name) catch |err| {
                report.err("publr: putting back backup {s}: {t}", .{ name, err });
            };
        }
    }

    // The path names the new binary now: this process still runs the old file, renamed.
    const installed = strip_suffix(executable);

    replace(init, installed);
}

fn restore(init: std.process.Init, db_path: []const u8, name: []const u8) !void {
    std.debug.assert(name.len > 0);

    const arena = init.arena.allocator();
    const site = try backup.Site.of(init.io, arena, db_path, null);

    for (try backup.list(site, arena)) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            try backup.restore(site, arena, entry);
            return;
        }
    }

    return error.FileNotFound;
}

/// `/usr/local/bin/publr.previous` is the file this process started from; the binary at the
/// path it was started by is `/usr/local/bin/publr`.
fn strip_suffix(executable: []const u8) []const u8 {
    std.debug.assert(executable.len > 0);

    for ([_][]const u8{ ".previous", ".rolled-back" }) |suffix| {
        if (std.mem.endsWith(u8, executable, suffix)) {
            return executable[0 .. executable.len - suffix.len];
        }
    }

    return executable;
}

fn replace(init: std.process.Init, executable: []const u8) void {
    std.debug.assert(executable.len > 0);

    const arena = init.arena.allocator();
    var iterator = init.minimal.args.iterateAllocator(arena) catch return;
    var argv: std.ArrayList([]const u8) = .empty;

    _ = iterator.next();
    argv.append(arena, executable) catch return;

    while (iterator.next()) |arg| {
        argv.append(arena, arg) catch return;
    }

    const err = std.process.replace(init.io, .{
        .argv = argv.items,
    });

    report.err("publr: could not restart as {s}: {t}", .{ executable, err });
}

test "the binary a restart becomes is the one at the path this one was started by" {
    try std.testing.expectEqualStrings("/bin/publr", strip_suffix("/bin/publr.previous"));
    try std.testing.expectEqualStrings("/bin/publr", strip_suffix("/bin/publr.rolled-back"));
    try std.testing.expectEqualStrings("/bin/publr", strip_suffix("/bin/publr"));
}
