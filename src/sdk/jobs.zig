//! Queued jobs (`publr.job.define`) run by the worker (`publr queue-run`): the due ones
//! claimed, each run as its plugin, then removed, or moved later when it fails, until its
//! last attempt keeps it as failed and tells the job's `on_failure`.
const std = @import("std");
const sdk = @import("../sdk.zig");
const job_queue = @import("../store/job_queue.zig");
const job_define = @import("plugin/job_define.zig");
const webhook_define = @import("plugin/webhook_define.zig");
const hook_runs = @import("hook_runs.zig");
const plugin_context = @import("plugin/context.zig");
const store_settings = @import("../store/settings.zig");
const zone = @import("../lib/zone.zig");
const language = @import("../operations/user/language.zig");

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

/// The administrator's time and pause for a repeating job, kept under `schedule_key`.
pub const Schedule = struct {
    hour: u8,
    minute: u8,
    paused: bool = false,
};

/// Where a repeating job's `Schedule` is kept among the site's settings.
pub fn schedule_key(
    arena: std.mem.Allocator,
    plugin: []const u8,
    name: []const u8,
) error{OutOfMemory}![]const u8 {
    std.debug.assert(plugin.len > 0 and name.len > 0);
    std.debug.assert(plugin.len + name.len < 1024);

    return std.fmt.allocPrint(arena, "job_schedule:{s}.{s}", .{ plugin, name });
}

/// The setting that names the site's time zone (`Europe/Warsaw`); UTC without it.
pub const zone_key = "time_zone";

/// The rule of the site's time zone.
pub fn zone_rule(ctx: *Ctx) job_queue.Error![]const u8 {
    std.debug.assert(ctx.now_ms >= 0);
    std.debug.assert(zone_key.len > 0);

    const name = try store_settings.get(ctx.db, ctx.arena, zone_key) orelse return "UTC0";

    return zone.rule_of(name) orelse "UTC0";
}

/// The first moment after `now_ms` a job repeating `every`, `at` runs, `at` read on the
/// clock of the zone with `rule`.
pub fn next_in_zone(every: job_define.Every, at: job_define.At, now_ms: i64, rule: []const u8) i64 {
    std.debug.assert(now_ms >= 0);
    std.debug.assert(rule.len > 0);

    var local = job_define.next_after(every, at, now_ms + zone.offset_ms(rule, now_ms));
    var utc = zone.utc_of(rule, local);

    // A clock turned back can put the next moment before now: the one after it, then.
    while (utc <= now_ms) {
        local = job_define.next_after(every, at, local);
        utc = zone.utc_of(rule, local);
    }

    std.debug.assert(utc > now_ms);

    return utc;
}

pub fn Jobs(comptime SDK: type, comptime registry: sdk.Registry) type {
    comptime std.debug.assert(registry.jobs.len == registry.job_owners.len);

    return struct {
        /// The due jobs run, up to `max`; answers how many ran, failed or not.
        pub fn drain(ctx: *Ctx, max: u32) job_queue.Error!u32 {
            std.debug.assert(ctx.db.transaction_depth == 0);
            std.debug.assert(max > 0 and max <= job_queue.take_max);

            const claimed = try job_queue.claim(ctx.db, ctx.arena, ctx.now_ms, claim_ms, max);
            const site = language.site_speaks(ctx) catch |err| blk: {
                std.log.warn("jobs: the site's language not read: {t}", .{err});
                break :blk "";
            };

            for (claimed) |job| {
                _ = ctx.allocate_operation_id();

                // The run is the author of what it changes (`job:<plugin>.<name>`).
                ctx.job = std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ job.plugin, job.name }) catch
                    return error.OutOfMemory;
                defer ctx.job = "";

                // Its `ctx.t` speaks the language it was queued with, else the site's.
                const before = ctx.language;

                ctx.language = .{
                    .locale = if (job.language.len > 0) job.language else site,
                };
                defer ctx.language = before;

                // What the run logs is kept as its own, whatever it calls inside.
                var lines: sdk.trail.Lines = .{
                    .root = 0,
                    .arena = ctx.arena,
                };

                std.debug.assert(ctx.lines == null);
                ctx.lines = &lines;
                defer ctx.lines = null;

                // An `on` hook's run (`on:<event>`) logs as its event's.
                const hook = hook_runs.target_of(job.name);
                const problem = if (hook != null)
                    SDK.events.run_hook(ctx, job.plugin, job.name, job.input)
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

        /// Each repeating job with nothing waiting and not paused, queued at its next moment:
        /// after it ran, failed for good, or on a fresh database. Answers how many were
        /// queued.
        pub fn repeat(ctx: *Ctx) job_queue.Error!u32 {
            std.debug.assert(ctx.db.transaction_depth == 0);
            std.debug.assert(ctx.now_ms >= 0);

            const rule = try zone_rule(ctx);
            var queued: u32 = 0;

            for (try repeating(ctx)) |job| {
                if (job.paused or try job_queue.waiting_for(ctx.db, job.plugin, job.name)) {
                    continue;
                }

                try queue_next(ctx, job, rule);
                queued += 1;
            }

            return queued;
        }

        /// The repeating jobs' waiting runs queued again for their times now: after the
        /// administrator changed one (`plugin`, `name`), or the site's time zone (all).
        pub fn reschedule(ctx: *Ctx, plugin: ?[]const u8, name: []const u8) job_queue.Error!void {
            std.debug.assert(ctx.now_ms >= 0);
            std.debug.assert(plugin == null or name.len > 0);

            const rule = try zone_rule(ctx);

            for (try repeating(ctx)) |job| {
                if (plugin) |only| {
                    if (!std.mem.eql(u8, only, job.plugin) or !std.mem.eql(u8, name, job.name)) {
                        continue;
                    }
                }

                try job_queue.forget_waiting(ctx.db, job.plugin, job.name, ctx.now_ms);

                if (!job.paused) {
                    try queue_next(ctx, job, rule);
                }
            }
        }

        /// A repeating job as declared, with the administrator's time and pause over it.
        pub const Repeating = struct {
            plugin: []const u8,
            name: []const u8,
            every: job_define.Every,
            at: job_define.At,
            paused: bool = false,
        };

        /// Every repeating job, compiled in and installed, as the administrator set it.
        pub fn repeating(ctx: *Ctx) job_queue.Error![]const Repeating {
            std.debug.assert(ctx.now_ms >= 0);
            std.debug.assert(registry.jobs.len == registry.job_owners.len);

            var list: std.ArrayList(Repeating) = .empty;

            inline for (registry.jobs, registry.job_owners) |Job, owner| {
                if (comptime Job.every) |every| {
                    try list.append(ctx.arena, try chosen(ctx, .{
                        .plugin = owner,
                        .name = Job.verb,
                        .every = every,
                        .at = Job.at,
                    }));
                }
            }

            if (ctx.sandboxed_plugins) |sandboxed| {
                for (sandboxed.manifests()) |manifest| {
                    for (manifest.jobs) |declared| {
                        try list.append(ctx.arena, try chosen(ctx, .{
                            .plugin = manifest.name,
                            .name = declared.name,
                            .every = every_of(declared) orelse continue,
                            .at = .{
                                .hour = declared.hour,
                                .minute = declared.minute,
                            },
                        }));
                    }
                }
            }

            return list.items;
        }

        fn chosen(ctx: *Ctx, declared: Repeating) job_queue.Error!Repeating {
            std.debug.assert(declared.plugin.len > 0 and declared.name.len > 0);
            std.debug.assert(declared.at.hour < 24 and declared.at.minute < 60);

            const key = try schedule_key(ctx.arena, declared.plugin, declared.name);
            const text = try store_settings.get(ctx.db, ctx.arena, key) orelse return declared;
            const set = std.json.parseFromSliceLeaky(Schedule, ctx.arena, text, .{
                .ignore_unknown_fields = true,
            }) catch return declared;
            var made = declared;

            if (set.hour < 24 and set.minute < 60) {
                made.at = .{
                    .hour = set.hour,
                    .minute = set.minute,
                };
            }

            made.paused = set.paused;

            return made;
        }

        fn queue_next(ctx: *Ctx, job: Repeating, rule: []const u8) job_queue.Error!void {
            std.debug.assert(!job.paused);
            std.debug.assert(ctx.now_ms >= 0);

            try job_queue.push(ctx.db, .{
                .plugin = job.plugin,
                .name = job.name,
                .input = "{}",
                .due_at_ms = next_in_zone(job.every, job.at, ctx.now_ms, rule),
                .now_ms = ctx.now_ms,
            });
        }

        /// A record just written: each `.due` job following one of its type's fields queued
        /// for the field's moment, when that moved (`job_queue.follow`).
        pub fn follow(ctx: *Ctx, record: []const u8) job_queue.Error!void {
            std.debug.assert(ctx.now_ms >= 0);
            std.debug.assert(record.len > 0);

            inline for (registry.jobs, registry.job_owners) |Job, owner| {
                if (comptime Job.due_on) |due| {
                    try follow_one(ctx, owner, Job.verb, due, record);
                }
            }

            const sandboxed = ctx.sandboxed_plugins orelse return;

            for (sandboxed.manifests()) |manifest| {
                for (manifest.jobs) |declared| {
                    const due = declared.due orelse continue;

                    try follow_one(ctx, manifest.name, declared.name, due, record);
                }
            }
        }

        fn follow_one(
            ctx: *Ctx,
            plugin: []const u8,
            name: []const u8,
            due: job_define.Due,
            record: []const u8,
        ) job_queue.Error!void {
            std.debug.assert(plugin.len > 0 and name.len > 0);
            std.debug.assert(due.field.len > 0);

            const moment = try job_queue.moment_of(ctx.db, record, due.type, due.field) orelse
                return;

            try job_queue.follow(ctx.db, ctx.arena, .{
                .plugin = plugin,
                .name = name,
                .record = record,
                .moment = moment,
                .offset_ms = due.offset_ms,
                .now_ms = ctx.now_ms,
                .language = ctx.language_queued(),
            });
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
            const delivery = webhook_delivery(ctx, job) catch |err| return @errorName(err);
            const input = if (delivery) |kept| kept.input else job.input;

            ctx.failure = null;

            sandboxed.job(ctx, job.plugin, job.name, input, last) catch |err| {
                const said = if (ctx.failure) |failure| failure.message else "";
                const problem = if (said.len > 0) said else @errorName(err);

                if (delivery) |kept| {
                    const result = if (last) "failed" else "waiting";

                    webhook_define.settled(ctx, kept.id, result, problem) catch |unsettled| {
                        std.log.warn("webhook delivery {d} not settled: {t}", .{
                            kept.id,
                            unsettled,
                        });
                    };
                }

                return if (err == error.Conflict) conflicted(ctx, problem) else problem;
            };

            if (delivery) |kept| {
                webhook_define.settled(ctx, kept.id, "ran", "") catch |err| return @errorName(err);
            }

            return "";
        }

        const Delivery = struct {
            id: i64,
            input: []const u8,
        };

        /// An installed plugin's webhook run (`webhook_<name>`): its delivery handed over
        /// whole, as its sandbox has no store to read it from. Null for any other job.
        fn webhook_delivery(ctx: *Ctx, job: job_queue.Claimed) !?Delivery {
            std.debug.assert(job.name.len > 0);
            std.debug.assert(job.input.len > 0);

            if (!std.mem.startsWith(u8, job.name, "webhook_")) {
                return null;
            }

            const queued = try std.json.parseFromSliceLeaky(
                webhook_define.Queued,
                ctx.arena,
                job.input,
                .{
                    .ignore_unknown_fields = true,
                },
            );
            const deliveries = @import("../store/webhook_deliveries.zig");
            const kept = try deliveries.get(ctx.db, ctx.arena, queued.delivery) orelse {
                return error.NotFound;
            };

            return .{
                .id = queued.delivery,
                .input = try std.json.Stringify.valueAlloc(ctx.arena, webhook_define.Queued{
                    .delivery = queued.delivery,
                    .body = kept.body,
                    .headers = kept.headers,
                }, .{}),
            };
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

            if (comptime Job.due_on != null) {
                return run_due(ctx, Job, owner, job);
            }

            const input = std.json.parseFromSliceLeaky(Job.Input, ctx.arena, job.input, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            }) catch return "its input no longer reads as the job's";

            return run_input(ctx, Job, owner, job.attempts, input);
        }

        /// A `.due` job, given its record as it is now; a record gone or in the trash runs
        /// nothing.
        fn run_due(
            ctx: *Ctx,
            comptime Job: type,
            comptime owner: []const u8,
            job: job_queue.Claimed,
        ) []const u8 {
            comptime std.debug.assert(Job.due_on != null);
            std.debug.assert(job.input.len > 0);

            const due = std.json.parseFromSliceLeaky(job_define.DueInput, ctx.arena, job.input, .{
                .ignore_unknown_fields = true,
            }) catch return "its input no longer reads as the job's";
            const running = ctx.plugin;
            const was_code = ctx.plugin_code;

            ctx.plugin = owner;
            ctx.plugin_code = true;
            defer ctx.plugin = running;
            defer ctx.plugin_code = was_code;

            var wrapped: PluginCtx = .{
                .inner = ctx,
            };
            const held = Job.Record.get(&wrapped, due.record, .{}) catch |err| {
                return if (err == error.NotFound) "" else @errorName(err);
            };

            return run_input(ctx, Job, owner, job.attempts, held);
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
                        Job.on_failure(&queued, err);
                    } else {
                        Job.on_failure(&queued, input, err);
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

test "a failing job runs again later, then is kept as failed and its on_failure hears the error" {
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

        fn gave_up(ctx: *QueueCtx, in: In, err: sdk.Error) void {
            std.debug.assert(in.word.len > 0);

            ctx.base.inner.dependency_failure = err == error.Failed and
                std.mem.eql(u8, ctx.failure(), "Busy");
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

test "queued work applies a mod and calls an operation by name, as a request's code does" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.system);
    var wrapped: PluginCtx = .{
        .inner = &ctx,
    };
    var queued: QueueCtx = .{
        .base = &wrapped,
    };

    const greeting: []const u8 = "Hello";

    try std.testing.expectEqualStrings("Hello", try queued.mod("probe.greeting", greeting));
    try std.testing.expectError(error.NotFound, queued.call_json("probe.nothing", "{}"));
}

test "a .due job runs once per moment of its record's field, moved by edits, given the record" {
    const registry = @import("../server/registry.zig");
    const model = @import("../model.zig");
    const record_define = @import("plugin/record_define.zig");
    const words = @import("plugin/words.zig");
    const records = @import("../operations/record.zig");
    const types = @import("../operations/content_type.zig");
    const Event = struct {
        title: []const u8,
        starts_at: ?words.Time = null,
    };
    const Docs = @import("plugin/define.zig").Words(.{
        .{ @typeName(Event), "Event" },
        .{ @typeName(Event) ++ ".title", "Title" },
        .{ @typeName(Event) ++ ".starts_at", "Starts" },
    });
    const Events = record_define.define(Event, .{
        .name = "probe.event",
    });
    const Probe = struct {
        var heard: []const u8 = "";

        fn run(ctx: *QueueCtx, event: Events.Held) sdk.Error!void {
            std.debug.assert(event.id.len > 0);

            heard = try ctx.base.inner.arena.dupe(u8, event.value.title);
        }
    };
    const Remind = job_define.define(Events, .{
        .name = "remind",
        .run = Probe.run,
        .due = .{
            .field = .starts_at,
            .before = .{
                .hours = 1,
            },
        },
    });
    const Runner = sdk.SDK(.{
        .operations = &.{},
        .jobs = &.{Remind},
        .job_owners = &.{"probe"},
    }).jobs;

    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.system);
    const hour_ms: i64 = 60 * 60 * 1000;
    const start = ctx.now_ms;

    try registry.SDK.bootstrap(&ctx);
    const declared = comptime record_define.content_type_of(Events, Docs);

    _ = try registry.SDK.dispatch(&ctx, types.Create, .{
        .definition = try model.content_type.encode(ctx.arena, declared),
    });

    const launch = "{{\"title\":\"Launch\",\"starts_at\":{d}}}";
    const document = try std.fmt.allocPrint(ctx.arena, launch, .{start + 3 * hour_ms});
    const created = try registry.SDK.dispatch(&ctx, records.Create, .{
        .type = "probe.event",
        .document = document,
    });

    try Runner.follow(&ctx, created.id);
    try std.testing.expectEqual(start + 2 * hour_ms, (try job_queue.next_due(ctx.db)).?);

    // Another field's edit leaves the job as it was.
    _ = try registry.SDK.dispatch(&ctx, records.Save, .{
        .id = created.id,
        .document = "{\"title\":\"Launch day\"}",
    });
    try Runner.follow(&ctx, created.id);
    try std.testing.expectEqual(1, (try job_queue.list(ctx.db, ctx.arena, 8)).len);

    // Moved into the past: queued at once, in place of the old moment's.
    const sooner = try std.fmt.allocPrint(ctx.arena, "{{\"starts_at\":{d}}}", .{
        start + 30 * 60 * 1000,
    });

    _ = try registry.SDK.dispatch(&ctx, records.Save, .{
        .id = created.id,
        .document = sooner,
    });
    try Runner.follow(&ctx, created.id);
    try std.testing.expectEqual(1, (try job_queue.list(ctx.db, ctx.arena, 8)).len);
    try std.testing.expectEqual(start, (try job_queue.next_due(ctx.db)).?);
    try std.testing.expectEqual(1, try Runner.drain(&ctx, 8));
    try std.testing.expectEqualStrings("Launch day", Probe.heard);

    // The value it ran for queues nothing again.
    try Runner.follow(&ctx, created.id);
    try std.testing.expectEqual(null, try job_queue.next_due(ctx.db));
}

test "a repeating job runs at its time on the site's clock; moved or paused by the administrator" {
    const Tidy = struct {
        fn run(ctx: *QueueCtx) sdk.Error!void {
            std.debug.assert(ctx.base.inner.now_ms >= 0);
        }
    };
    const Nightly = job_define.define_recurring(.{
        .name = "tidy",
        .run = Tidy.run,
        .every = .day,
        .at = .{
            .hour = 3,
        },
    });
    const Runner = sdk.SDK(.{
        .operations = &.{},
        .jobs = &.{Nightly},
        .job_owners = &.{"probe"},
    }).jobs;

    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.system);
    const hour_ms: i64 = 60 * 60 * 1000;

    // 2026-07-15 12:00 UTC; 03:00 in Warsaw (summer) is 01:00 UTC.
    ctx.now_ms = 1_784_116_800_000;
    try store_settings.set(ctx.db, zone_key, "Europe/Warsaw", ctx.now_ms);
    try std.testing.expectEqual(1, try Runner.repeat(&ctx));
    try std.testing.expectEqual(ctx.now_ms + 13 * hour_ms, (try job_queue.next_due(ctx.db)).?);

    // Moved to 05:30: its waiting run follows.
    const key = try schedule_key(ctx.arena, "probe", "tidy");

    try store_settings.set(ctx.db, key, "{\"hour\":5,\"minute\":30}", ctx.now_ms);
    try Runner.reschedule(&ctx, "probe", "tidy");
    try std.testing.expectEqual(
        ctx.now_ms + 15 * hour_ms + 30 * 60 * 1000,
        (try job_queue.next_due(ctx.db)).?,
    );

    // Paused: nothing waits, and nothing is queued again.
    try store_settings.set(ctx.db, key, "{\"hour\":5,\"minute\":30,\"paused\":true}", ctx.now_ms);
    try Runner.reschedule(&ctx, "probe", "tidy");
    try std.testing.expectEqual(null, try job_queue.next_due(ctx.db));
    try std.testing.expectEqual(0, try Runner.repeat(&ctx));
}
