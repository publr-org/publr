//! Queued jobs (`publr.job.define`) run by the worker (`publr queue-run`): the due ones
//! claimed, each run as its plugin, then removed, or moved later when it fails, until its
//! last attempt keeps it as failed and tells the job's `on_failure`.
const std = @import("std");
const sdk = @import("../sdk.zig");
const job_queue = @import("../store/job_queue.zig");
const job_define = @import("plugin/job_define.zig");
const hook_runs = @import("hook_runs.zig");
const plugin_context = @import("plugin/context.zig");

const Ctx = sdk.Ctx;
const PluginCtx = plugin_context.HostApi;
const QueueCtx = @import("plugin/queue.zig").Queue(PluginCtx);

/// How long a run holds its job: longer than any job should take, short enough that one
/// lost to a crash runs again soon.
pub const claim_ms: i64 = 5 * 60 * 1000;

/// How often an installed plugin's repeating job runs, from its manifest; null for one code
/// queues.
fn every_of(declared: sdk.sandboxed_plugins.Job) ?job_define.Every {
    std.debug.assert(declared.name.len > 0);
    std.debug.assert(declared.hour < 24 and declared.minute < 60);

    if (std.mem.eql(u8, declared.every, "day")) {
        return .day;
    }

    if (std.mem.eql(u8, declared.every, "hour")) {
        return .hour;
    }

    if (std.mem.eql(u8, declared.every, "minutes") and declared.minutes > 0) {
        return .{
            .minutes = declared.minutes,
        };
    }

    return null;
}

pub fn Jobs(comptime SDK: type, comptime registry: sdk.Registry) type {
    comptime std.debug.assert(registry.jobs.len == registry.job_owners.len);

    return struct {
        /// The due jobs run, up to `max`; answers how many ran, failed or not.
        pub fn drain(ctx: *Ctx, max: u32) job_queue.Error!u32 {
            std.debug.assert(ctx.db.transaction_depth == 0);
            std.debug.assert(max > 0 and max <= job_queue.take_max);

            const claimed = try job_queue.claim(ctx.db, ctx.arena, ctx.now_ms, claim_ms, max);

            for (claimed) |job| {
                _ = ctx.allocate_operation_id();

                // The run is the author of what it changes (`job:<plugin>.<name>`).
                ctx.job = std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ job.plugin, job.name }) catch
                    return error.OutOfMemory;
                defer ctx.job = "";

                // What the run logs is kept as its own, whatever it calls inside.
                var lines: sdk.trail.Lines = .{
                    .root = 0,
                    .arena = ctx.arena,
                };

                std.debug.assert(ctx.lines == null);
                ctx.lines = &lines;
                defer ctx.lines = null;

                // An `on` hook's run kept to run again (`on:<event>`) logs as its event's.
                const hook = hook_runs.target_of(job.name);
                const problem = if (hook != null)
                    SDK.events.rerun(ctx, job.plugin, job.name, job.input)
                else
                    run_one(ctx, job);

                try settle(ctx, job, problem);

                if (hook) |target| {
                    try SDK.events.keep_lines(ctx, target.event, &lines);
                } else if (registry.log) |log| {
                    if (lines.items.items.len > 0) {
                        const call = try std.fmt.allocPrint(ctx.arena, "job:{s}", .{ctx.job});

                        SDK.raise_failed(ctx, log.lines(ctx, call, lines.kept()));
                    }
                }
            }

            return @intCast(claimed.len);
        }

        /// Each repeating job with nothing waiting, queued at its next moment: after it ran,
        /// failed for good, or on a fresh database. Answers how many were queued.
        pub fn repeat(ctx: *Ctx) job_queue.Error!u32 {
            std.debug.assert(ctx.db.transaction_depth == 0);
            std.debug.assert(ctx.now_ms >= 0);

            var queued: u32 = 0;

            if (ctx.sandboxed_plugins) |sandboxed| {
                queued += try repeat_installed(ctx, sandboxed);
            }

            inline for (registry.jobs, registry.job_owners) |Job, owner| {
                if (comptime Job.every) |every| {
                    if (!try job_queue.waiting_for(ctx.db, owner, Job.verb)) {
                        try job_queue.push(ctx.db, .{
                            .plugin = owner,
                            .name = Job.verb,
                            .input = "{}",
                            .due_at_ms = job_define.next_after(every, Job.at, ctx.now_ms),
                            .now_ms = ctx.now_ms,
                        });
                        queued += 1;
                    }
                }
            }

            return queued;
        }

        fn repeat_installed(
            ctx: *Ctx,
            sandboxed: *const sdk.sandboxed_plugins.SandboxedPlugins,
        ) job_queue.Error!u32 {
            std.debug.assert(ctx.db.transaction_depth == 0);
            std.debug.assert(ctx.now_ms >= 0);

            var queued: u32 = 0;

            for (sandboxed.manifests()) |manifest| {
                for (manifest.jobs) |declared| {
                    const every = every_of(declared) orelse continue;

                    if (try job_queue.waiting_for(ctx.db, manifest.name, declared.name)) {
                        continue;
                    }

                    try job_queue.push(ctx.db, .{
                        .plugin = manifest.name,
                        .name = declared.name,
                        .input = "{}",
                        .due_at_ms = job_define.next_after(every, .{
                            .hour = declared.hour,
                            .minute = declared.minute,
                        }, ctx.now_ms),
                        .now_ms = ctx.now_ms,
                    });
                    queued += 1;
                }
            }

            return queued;
        }

        /// The job's own words for why it failed; empty when it ran.
        fn run_one(ctx: *Ctx, job: job_queue.Claimed) []const u8 {
            std.debug.assert(job.id > 0);
            std.debug.assert(job.plugin.len > 0);

            if (std.mem.eql(u8, job.plugin, job_queue.core)) {
                const run = registry.core_job orelse return gone;

                return run(ctx, job.name, job.input);
            }

            inline for (registry.jobs, registry.job_owners) |Job, owner| {
                const same = std.mem.eql(u8, job.plugin, owner) and
                    std.mem.eql(u8, job.name, Job.verb);

                if (same) {
                    return run_as(ctx, Job, owner, job);
                }
            }

            const sandboxed = ctx.sandboxed_plugins orelse return gone;

            if (sandboxed.job_of(job.plugin, job.name) == null) {
                return gone;
            }

            return run_installed(ctx, sandboxed, job);
        }

        const gone = "no such job: its plugin is gone or no longer has it";
        const conflicted_prefix = "Conflicted: ";

        /// A run that ended in `Conflict`: kept as failed, said so.
        fn conflicted(ctx: *Ctx, problem: []const u8) []const u8 {
            std.debug.assert(problem.len > 0);
            std.debug.assert(ctx.now_ms >= 0);

            return std.fmt.allocPrint(ctx.arena, conflicted_prefix ++ "{s}", .{problem}) catch
                conflicted_prefix;
        }

        /// An installed plugin's job, run in its sandbox as the plugin.
        fn run_installed(
            ctx: *Ctx,
            sandboxed: *const sdk.sandboxed_plugins.SandboxedPlugins,
            job: job_queue.Claimed,
        ) []const u8 {
            std.debug.assert(job.id > 0);
            std.debug.assert(job.input.len > 0);

            const last = job.attempts + 1 >= job_define.attempts_max;

            ctx.failure = null;

            sandboxed.job(ctx, job.plugin, job.name, job.input, last) catch |err| {
                const said = if (ctx.failure) |failure| failure.message else "";
                const problem = if (said.len > 0) said else @errorName(err);

                return if (err == error.Conflict) conflicted(ctx, problem) else problem;
            };

            return "";
        }

        fn run_as(
            ctx: *Ctx,
            comptime Job: type,
            comptime owner: []const u8,
            job: job_queue.Claimed,
        ) []const u8 {
            comptime std.debug.assert(job_define.is_job(Job));
            std.debug.assert(job.input.len > 0);

            if (comptime Job.Input == void) {
                return run_input(ctx, Job, owner, job.attempts, {});
            }

            const input = std.json.parseFromSliceLeaky(Job.Input, ctx.arena, job.input, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            }) catch return "its input no longer reads as the job's";

            return run_input(ctx, Job, owner, job.attempts, input);
        }

        fn run_input(
            ctx: *Ctx,
            comptime Job: type,
            comptime owner: []const u8,
            attempts: i64,
            input: Job.Input,
        ) []const u8 {
            comptime std.debug.assert(owner.len > 0);
            std.debug.assert(ctx.now_ms >= 0);

            const running = ctx.plugin;

            ctx.plugin = owner;
            defer ctx.plugin = running;

            const was_code = ctx.plugin_code;

            ctx.plugin_code = true;
            defer ctx.plugin_code = was_code;

            var wrapped: PluginCtx = .{
                .inner = ctx,
            };
            var queued: QueueCtx = .{
                .base = &wrapped,
            };

            ctx.failure = null;

            const ran = if (comptime Job.Input == void)
                Job.run(&queued)
            else
                Job.run(&queued, input);

            ran catch |err| {
                const said = if (ctx.failure) |failure| failure.message else "";
                const problem = if (said.len > 0) said else @errorName(err);
                const last = attempts + 1 >= job_define.attempts_max;

                if (err == error.Conflict) {
                    if (comptime @TypeOf(Job.on_conflict) != @TypeOf(null)) {
                        if (comptime Job.Input == void) {
                            Job.on_conflict(&queued);
                        } else {
                            Job.on_conflict(&queued, input);
                        }
                    }

                    return conflicted(ctx, problem);
                }

                if (last and comptime @TypeOf(Job.on_failure) != @TypeOf(null)) {
                    if (comptime Job.Input == void) {
                        Job.on_failure(&queued, problem);
                    } else {
                        Job.on_failure(&queued, input, problem);
                    }
                }

                return problem;
            };

            return "";
        }

        fn settle(ctx: *Ctx, job: job_queue.Claimed, problem: []const u8) job_queue.Error!void {
            std.debug.assert(job.id > 0);
            std.debug.assert(job.attempts >= 0);

            if (problem.len == 0) {
                return job_queue.done(ctx.db, job.id);
            }

            const attempts: u32 = @intCast(job.attempts);
            const ends = ends_after(attempts, problem);

            try note_failure(ctx, job.plugin, job.name, attempts + 1, ends, problem);

            if (ends) {
                return job_queue.fail(ctx.db, job.id, problem);
            }

            const due_at_ms = ctx.now_ms + job_define.backoff_ms(attempts);

            return job_queue.retry(ctx.db, job.id, due_at_ms, problem);
        }

        /// Work whose first run failed outside the queue (an `on` hook's): kept as a job
        /// after that one attempt, to run again as a failed job does, or failed for good.
        pub fn failed_first(
            ctx: *Ctx,
            first: job_queue.Queued,
            problem: []const u8,
        ) job_queue.Error!void {
            std.debug.assert(first.plugin.len > 0 and first.name.len > 0);
            std.debug.assert(problem.len > 0);

            var kept = first;
            var why = problem;
            var ends = ends_after(0, problem);

            if (kept.input.len > job_queue.input_bytes_max) {
                kept.input = "null";
                why = try std.fmt.allocPrint(ctx.arena, too_large ++ "{s}", .{problem});
                ends = true;
            }

            kept.due_at_ms = ctx.now_ms + job_define.backoff_ms(0);

            try note_failure(ctx, kept.plugin, kept.name, 1, ends, why);

            return job_queue.push_failed(ctx.db, kept, ends, why);
        }

        const too_large = "Not run again: its event is over 64 KiB. ";

        /// Whether a run that failed after `attempts` earlier ones is not run again: a
        /// conflict, or the last attempt.
        fn ends_after(attempts: u32, problem: []const u8) bool {
            std.debug.assert(problem.len > 0);
            std.debug.assert(attempts < job_define.attempts_max);

            return std.mem.startsWith(u8, problem, conflicted_prefix) or
                attempts + 1 >= job_define.attempts_max;
        }

        /// The failure on the plugin's Log, beside what the run logged: try `tries` of the
        /// most, or failed for good.
        fn note_failure(
            ctx: *Ctx,
            plugin: []const u8,
            name: []const u8,
            tries: u32,
            ends: bool,
            problem: []const u8,
        ) error{OutOfMemory}!void {
            std.debug.assert(tries > 0 and tries <= job_define.attempts_max);
            std.debug.assert(problem.len > 0);

            std.log.warn("job {s}.{s}: {s}", .{ plugin, name, problem });

            const lines = ctx.lines orelse return;
            const hook = hook_runs.target_of(name);
            const what = if (hook) |target|
                try std.fmt.allocPrint(ctx.arena, "The hook on {s}", .{target.event})
            else
                try std.fmt.allocPrint(ctx.arena, "The job {s}", .{name});
            const plural: []const u8 = if (tries == 1) "try" else "tries";
            const text = if (ends)
                try std.fmt.allocPrint(ctx.arena, "{s} failed for good after {d} {s}: {s}", .{
                    what,
                    tries,
                    plural,
                    problem,
                })
            else
                try std.fmt.allocPrint(ctx.arena, "{s} failed (try {d} of {d}): {s}", .{
                    what,
                    tries,
                    job_define.attempts_max,
                    problem,
                });

            lines.add(.{
                .plugin = plugin,
                .level = .err,
                .text = text,
            });
        }
    };
}

test "a failing job runs again later, then is kept as failed and its on_failure hears why" {
    const Probe = struct {
        const In = struct {
            word: []const u8,
        };

        fn run(ctx: *QueueCtx, in: In) sdk.Error!void {
            std.debug.assert(in.word.len > 0);

            return ctx.base.inner.fail(.{
                .name = "Busy",
                .status = 409,
                .message = "the other side is busy",
            });
        }

        fn gave_up(ctx: *QueueCtx, in: In, problem: []const u8) void {
            std.debug.assert(in.word.len > 0);

            ctx.base.inner.dependency_failure = std.mem.eql(u8, problem, "the other side is busy");
        }
    };
    const Failing = job_define.define(Probe.In, .{
        .name = "probe",
        .run = Probe.run,
        .on_failure = Probe.gave_up,
    });
    const Runner = sdk.SDK(.{
        .operations = &.{},
        .jobs = &.{Failing},
        .job_owners = &.{"probe"},
    }).jobs;

    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.system);

    try job_queue.push(ctx.db, .{
        .plugin = "probe",
        .name = "probe",
        .input = "{\"word\":\"hi\"}",
        .due_at_ms = ctx.now_ms,
        .now_ms = ctx.now_ms,
    });

    for (0..job_define.attempts_max) |attempt| {
        try std.testing.expectEqual(1, try Runner.drain(&ctx, 8));
        try std.testing.expectEqual(0, try Runner.drain(&ctx, 8));
        try std.testing.expectEqual(attempt + 1 == job_define.attempts_max, ctx.dependency_failure);

        ctx.now_ms += job_define.backoff_ms_max;
    }

    try std.testing.expectEqual(null, try job_queue.next_due(ctx.db));
    try std.testing.expectEqual(0, try Runner.drain(&ctx, 8));
}

test "a repeating job is queued once, runs at its moment, and is queued again for the next" {
    const Tidy = struct {
        fn run(ctx: *QueueCtx) sdk.Error!void {
            std.debug.assert(ctx.base.inner.now_ms >= 0);

            ctx.base.inner.dependency_failure = true;
        }
    };
    const Hourly = job_define.define_recurring(.{
        .name = "tidy",
        .run = Tidy.run,
        .every = .hour,
        .at = .{
            .minute = 15,
        },
    });
    const Runner = sdk.SDK(.{
        .operations = &.{},
        .jobs = &.{Hourly},
        .job_owners = &.{"probe"},
    }).jobs;

    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.system);

    ctx.now_ms = 1_792_405_800_000;

    try std.testing.expectEqual(1, try Runner.repeat(&ctx));
    try std.testing.expectEqual(0, try Runner.repeat(&ctx));
    try std.testing.expectEqual(ctx.now_ms + 45 * 60 * 1000, (try job_queue.next_due(ctx.db)).?);
    try std.testing.expectEqual(0, try Runner.drain(&ctx, 8));

    ctx.now_ms += 45 * 60 * 1000;

    try std.testing.expectEqual(1, try Runner.drain(&ctx, 8));
    try std.testing.expect(ctx.dependency_failure);
    try std.testing.expectEqual(1, try Runner.repeat(&ctx));
    try std.testing.expectEqual(ctx.now_ms + 60 * 60 * 1000, (try job_queue.next_due(ctx.db)).?);
}

test "a job ending in a conflict is heard by on_conflict, kept, and its run is the author" {
    const Probe = struct {
        const In = struct {
            word: []const u8,
        };

        fn run(ctx: *QueueCtx, in: In) sdk.Error!void {
            std.debug.assert(in.word.len > 0);

            // The run is the author of what it writes.
            if (!std.mem.eql(u8, ctx.base.inner.job, "probe.sync")) {
                return error.Invalid;
            }

            return error.Conflict;
        }

        fn kept(ctx: *QueueCtx, in: In) void {
            std.debug.assert(in.word.len > 0);

            ctx.base.inner.dependency_failure = true;
        }
    };
    const Syncing = job_define.define(Probe.In, .{
        .name = "sync",
        .run = Probe.run,
        .on_conflict = Probe.kept,
    });
    const Runner = sdk.SDK(.{
        .operations = &.{},
        .jobs = &.{Syncing},
        .job_owners = &.{"probe"},
    }).jobs;

    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.system);

    try job_queue.push(ctx.db, .{
        .plugin = "probe",
        .name = "sync",
        .input = "{\"word\":\"hi\"}",
        .due_at_ms = ctx.now_ms,
        .now_ms = ctx.now_ms,
    });

    try std.testing.expectEqual(1, try Runner.drain(&ctx, 8));
    try std.testing.expect(ctx.dependency_failure);
    try std.testing.expectEqualStrings("", ctx.job);
    try std.testing.expectEqual(null, try job_queue.next_due(ctx.db));

    const kept = try job_queue.list(ctx.db, ctx.arena, 8);

    try std.testing.expectEqual(1, kept.len);
    try std.testing.expectEqualStrings("failed", kept[0].state);
    try std.testing.expect(std.mem.startsWith(u8, kept[0].problem, "Conflicted: "));
}

test "queued work fetches through the plugin's grant: an anonymous caller is refused" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.anonymous);
    var wrapped: PluginCtx = .{
        .inner = &ctx,
    };
    var queued: QueueCtx = .{
        .base = &wrapped,
    };

    try std.testing.expectError(error.Denied, queued.fetch(.{
        .url = "https://api.example.com/quote",
    }));
}
