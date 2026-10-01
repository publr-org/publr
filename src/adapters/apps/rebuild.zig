//! The surgical rebuild that follows a change, planned by the dependency index every app
//! shares: `flush` between the server's ticks, and `refresh` at startup, which brings each
//! app's build up to date with the least work (nothing, the pending batches, or the app).

const std = @import("std");
const report = @import("../../lib/report.zig");
const sdk = @import("../../sdk.zig");
const deps = @import("../../lib/deps.zig");
const build = @import("build.zig");
const public = @import("public.zig");
const artifacts = @import("artifacts.zig");
const rerender = @import("rerender.zig");
const Project = @import("../../server/project.zig").Project;
const state = @import("state.zig");
const App = state.App;

/// The file a full build leaves in an app's output folder: the stamp that built it.
pub const marker_path = ".publr-build";
pub const marker_len_max: u32 = state.version_len + 1;
const batches_per_flush_max: u32 = 16;
/// How many batches a startup replays before giving up on the queue and building whole.
const batches_per_refresh_max: u32 = 1024;

/// What `refresh` did: nothing, the artifacts the pending changes reached, or whole apps.
pub const Outcome = enum { current, refreshed, built };

pub const Refreshed = struct {
    outcome: Outcome,
    /// Public files copied independently of generated pages.
    copied: u32 = 0,
    /// Pages and islands whose bytes changed and were written again.
    written: u32 = 0,
    /// Pages and islands the apps or the records no longer have.
    removed: u32 = 0,
    /// The full builds' figures when `outcome` is `built`.
    full: build.Summary = .{},
};

/// Every app's build brought up to date: no work for an app whose marker carries its stamp
/// while no change waits; the pending batches replayed when they do; an app built whole
/// when it has no build, its templates or its address changed, or a batch is too wide to
/// plan (`error.FanOutExceeded` is the index refusing, never a failure). An app whose build
/// fails is marked unavailable; the others go on.
pub fn refresh(project: *const Project) !Refreshed {
    std.debug.assert(project.connection.transaction_depth == 0);
    std.debug.assert(project.apps.len > 0);

    var result: Refreshed = .{ .outcome = .current };
    var stale: u32 = 0;

    for (project.apps) |*app| {
        if (app.program == null) {
            continue;
        }

        if (app.output == null) {
            app.open_existing_output();
        }

        if (app.output == null or !marker_matches(app)) {
            add(&result.full, build.build_or_fail(app, project));
            stale += 1;
        } else {
            result.copied += (try public.sync(app)).files;
        }
    }

    if (stale > 0) {
        result.outcome = .built;
    }

    const replayed = replay(project) catch |err| switch (err) {
        error.FanOutExceeded => return .{ .outcome = .built, .full = try build.build_all(project) },
        else => return err,
    };

    result.written += replayed.written;
    result.removed += replayed.removed;

    if (replayed.too_many) {
        return .{ .outcome = .built, .full = try build.build_all(project) };
    }

    if (result.outcome == .current and (result.written > 0 or result.removed > 0)) {
        result.outcome = .refreshed;
    }

    if (result.written > 0 or result.removed > 0) {
        write_sitemaps(project);
    }

    return result;
}

fn add(total: *build.Summary, summary: build.Summary) void {
    std.debug.assert(total.pages <= std.math.maxInt(u32) - summary.pages);
    std.debug.assert(total.islands <= std.math.maxInt(u32) - summary.islands);

    total.pages += summary.pages;
    total.islands += summary.islands;
    total.assets += summary.assets;
    total.bytes += summary.bytes;
    total.failed += summary.failed;
}

const Replayed = struct { written: u32 = 0, removed: u32 = 0, too_many: bool = false };

/// Every queued change, due now: a quiet period is for a server that keeps running.
fn replay(project: *const Project) !Replayed {
    std.debug.assert(project.apps.len > 0);
    std.debug.assert(batches_per_refresh_max > 0);

    const index = project.apps[0].index;
    var arena_state = std.heap.ArenaAllocator.init(project.apps[0].gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const later = sdk.context.wall_clock_ms(project.io) + deps.quiet_ms;
    var result: Replayed = .{};
    var batches: u32 = 0;

    while (batches < batches_per_refresh_max) : (batches += 1) {
        const batch = (try index.take(arena, later)) orelse return result;
        const counts = try rebuild_batch(project, arena, batch);

        result.written += counts.written;
        result.removed += counts.removed;
    }

    result.too_many = true;

    return result;
}

/// Whether the app's output folder was built by this app, at this address.
pub fn marker_matches(app: *const App) bool {
    std.debug.assert(app.output != null);
    std.debug.assert(app.program != null);

    var buffer: [marker_len_max]u8 = undefined;
    const out = app.output.?;
    const read = out.readFile(app.io, marker_path, &buffer) catch return false;
    const found = std.mem.trimEnd(u8, read, "\r\n");

    std.debug.assert(read.len <= marker_len_max);

    return std.mem.eql(u8, found, &app.build_stamp);
}

pub fn write_marker(app: *const App) !void {
    std.debug.assert(app.output != null);
    std.debug.assert(app.program != null);

    var buffer: [marker_len_max]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, "{s}\n", .{&app.build_stamp});

    std.debug.assert(line.len == marker_len_max);

    try app.output.?.writeFile(app.io, .{ .sub_path = marker_path, .data = line });
}

/// Takes every due batch and rebuilds its plan. Best effort: a failure leaves a stale file
/// and a line on stderr, never a failed request.
pub fn flush(project: *const Project, now_ms: i64) void {
    std.debug.assert(now_ms >= 0);
    std.debug.assert(project.connection.transaction_depth == 0);

    if (!built(project)) {
        return;
    }

    const index = project.apps[0].index;
    var arena_state = std.heap.ArenaAllocator.init(project.apps[0].gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var batches: u32 = 0;

    while (batches < batches_per_flush_max) : (batches += 1) {
        const batch = (index.take(arena, now_ms) catch return) orelse return;

        _ = rebuild_batch(project, arena, batch) catch |err| {
            report.err_reason(reason_of(project), "apps: rebuild refused: {s}", .{
                @errorName(err),
            });

            return;
        };

        write_sitemaps(project);
    }
}

/// Whether a batch waits to be taken: what `serve` asks between ticks.
pub fn due(project: *const Project, now_ms: i64) bool {
    std.debug.assert(now_ms >= 0);

    if (!built(project)) {
        return false;
    }

    const index = project.apps[0].index;

    std.debug.assert(index.options.quiet_ms == deps.quiet_ms);

    return index.due(now_ms) catch false;
}

/// Whether some app is served from a build: only then is there a folder to keep current.
fn built(project: *const Project) bool {
    std.debug.assert(project.apps.len <= 1024);

    for (project.apps) |*app| {
        if (app.output != null) {
            return true;
        }
    }

    return false;
}

const Counts = struct { written: u32 = 0, removed: u32 = 0 };

/// One batch through its plan and marked done: each artifact rendered again by the app
/// that wrote it. A plan the index refuses (`error.FanOutExceeded`) leaves the batch
/// waiting for the caller to decide.
fn rebuild_batch(project: *const Project, arena: std.mem.Allocator, batch: deps.Batch) !Counts {
    std.debug.assert(batch.no > 0);
    std.debug.assert(project.apps.len > 0);

    const index = project.apps[0].index;
    var counts: Counts = .{};

    for (project.apps) |*app| {
        if (app.output != null and app.program != null and app.build_ready) {
            counts.written += rerender.record_pages(app, project, arena, batch.keys);
        }
    }

    const plan = try index.plan(arena, batch);

    for (plan) |artifact| {
        const outcome = rebuild_artifact(project, arena, batch.no, artifact);

        switch (outcome) {
            .written => counts.written += 1,
            .removed => counts.removed += 1,
            .identical, .failed => {},
        }
    }

    try index.done(batch);

    return counts;
}

/// The artifact's own app renders it again; an artifact of an app this project no longer
/// has is forgotten.
fn rebuild_artifact(
    project: *const Project,
    arena: std.mem.Allocator,
    batch: u64,
    artifact: []const u8,
) deps.Outcome {
    std.debug.assert(artifact.len > 0);
    std.debug.assert(batch > 0);

    const index = project.apps[0].index;
    const parts = artifacts.split(artifact);
    const app = if (parts) |found| project.find(found.app) else null;

    if (app == null or parts == null) {
        index.forget(artifact) catch |err| {
            std.debug.print("apps: forget {s}: {s}\n", .{ artifact, @errorName(err) });
        };

        return .removed;
    }

    const owner = app.?;

    if (owner.output == null or owner.program == null or !owner.build_ready) {
        return .identical;
    }

    return rerender.artifact(owner, project, arena, batch, parts.?.url);
}

fn write_sitemaps(project: *const Project) void {
    std.debug.assert(project.apps.len > 0);
    std.debug.assert(project.connection.transaction_depth == 0);

    for (project.apps) |*app| {
        if (app.output == null or app.program == null or !app.build_ready) {
            continue;
        }

        build.write_sitemap(app, project) catch |err| {
            std.debug.print("apps: {s}: sitemap: {s}\n", .{ app.spec.name, @errorName(err) });
        };
    }
}

fn reason_of(project: *const Project) []const u8 {
    std.debug.assert(project.apps.len > 0);

    const reason = project.apps[0].options.diagnostic orelse return "";

    return reason.text();
}

test "the marker file can never be served as a page" {
    // `built_page` refuses any path with a dot-segment, so the marker stays private.
    try std.testing.expect(std.mem.startsWith(u8, marker_path, "."));
    try std.testing.expect(std.mem.indexOfScalar(u8, marker_path, '/') == null);
}
