const std = @import("std");
const sdk = @import("../sdk.zig");
const store = @import("../store.zig");
const registry = @import("../server/registry.zig");
const jobs = @import("../sdk/jobs.zig");
const zone = @import("../lib/zone.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const namespace: sdk.operation.Namespace = .{
    .name = "job",
    .label = "Queued work",
    .area = .system,
    .summary = "The work plugins queued, waiting or failed",
    .details =
    \\A plugin queues a job with `ctx.enqueue`, or declares one that repeats; the server's
    \\worker runs each once it is due, as its plugin, and removes it when it is done. A job
    \\that fails runs again later, up to eight times; after the last it stays here, failed,
    \\with why. An `on` hook that fails runs the same way, as its plugin's `on:<event>`.
    \\Repeating jobs run at times read on the site's clock (`project.set_time_zone`); the
    \\administrator may move a job's time or pause it (`job.schedule`).
    ,
};

pub const List = struct {
    pub const name = "job.list";
    pub const description = "The jobs waiting to run and the ones that failed for good";
    pub const details =
        \\Administrators only. Waiting jobs come first, soonest due first, then the failed
        \\ones; at most 200. Changes nothing.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        jobs: []const store.job_queue.Listed,
        /// The jobs that run again and again, as the administrator set them.
        repeating: []const Repeating = &.{},
        /// The site's time zone, which repeating jobs' times are read in.
        time_zone: []const u8 = "UTC",
    };
    pub const Repeating = struct {
        plugin: []const u8,
        name: []const u8,
        /// `day`, `hour` or `minutes`.
        every: []const u8,
        /// With `every` `minutes`: how many.
        minutes: u32 = 0,
        hour: u8,
        minute: u8,
        paused: bool,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .jobs = &.{.{
            .id = 7,
            .plugin = "hello",
            .name = "show",
            .input = "{\"greeting\":\"0a1b2c3d4e5f60718293a4b5\"}",
            .due_at = 1792405860000,
            .attempts = 0,
            .state = "waiting",
            .problem = "",
        }},
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .jobs = "Each job: its id, its plugin and name, its input as JSON, when it is due " ++
            "(ms), how many runs failed, `waiting` or `failed`, and the last problem",
        .repeating = "Each repeating job: its plugin and name, how often (`every`, " ++
            "`minutes`), the hour and minute it runs at on the site's clock, and whether " ++
            "it is paused",
        .time_zone = "The site's time zone, `UTC` unless one was chosen",
    };

    pub fn run(ctx: *Ctx, _: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        const declared = try registry.SDK.jobs.repeating(ctx);
        const repeating = try ctx.arena.alloc(Repeating, declared.len);

        for (declared, repeating) |job, *shown| {
            shown.* = .{
                .plugin = job.plugin,
                .name = job.name,
                .every = @tagName(job.every),
                .minutes = if (job.every == .minutes) job.every.minutes else 0,
                .hour = job.at.hour,
                .minute = job.at.minute,
                .paused = job.paused,
            };
        }

        return .{
            .jobs = try store.job_queue.list(ctx.db, ctx.arena, 200),
            .repeating = repeating,
            .time_zone = try store.settings.get(ctx.db, ctx.arena, jobs.zone_key) orelse "UTC",
        };
    }
};

pub const RunAgain = struct {
    pub const name = "job.run_again";
    pub const description = "Run a failed job again";
    pub const details =
        \\Administrators only. The job waits to run at once, its tries counted afresh, as it
        \\was first queued. Refused when no failed job has that id.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        job: i64,
    };
    pub const Out = struct {};
    pub const example: In = .{
        .job = 7,
    };
    pub const example_out: Out = .{};
    pub const field_docs: sdk.operation.Docs(In) = .{
        .job = "The failed job's id, from `job.list`",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.job <= 0) {
            return error.Invalid;
        }

        if (!try store.job_queue.run_again(ctx.db, in.job, ctx.now_ms)) {
            return error.NotFound;
        }

        return .{};
    }
};

pub const Schedule = struct {
    pub const name = "job.schedule";
    pub const description = "Move a repeating job's time, or pause it";
    pub const details =
        \\Administrators only. The hour and minute are read on the site's clock; a job that
        \\runs every hour takes only the minute, one every few minutes neither. A paused job
        \\runs no more until it is resumed; its waiting run is taken back. Refused for a job
        \\that does not repeat.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        plugin: []const u8,
        name: []const u8,
        hour: u8,
        minute: u8,
        paused: bool = false,
    };
    pub const Out = struct {};
    pub const example: In = .{
        .plugin = "shop",
        .name = "tidy_carts",
        .hour = 4,
        .minute = 30,
    };
    pub const example_out: Out = .{};
    pub const field_docs: sdk.operation.Docs(In) = .{
        .plugin = "The job's plugin",
        .name = "The job's name, from `job.list`'s `repeating`",
        .hour = "0 to 23, on the site's clock",
        .minute = "0 to 59",
        .paused = "Run no more until set false again",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.hour >= 24 or in.minute >= 60 or in.plugin.len == 0 or in.name.len == 0) {
            return error.Invalid;
        }

        if (!try repeats(ctx, in.plugin, in.name)) {
            return error.NotFound;
        }

        const key = try jobs.schedule_key(ctx.arena, in.plugin, in.name);
        const set = std.json.Stringify.valueAlloc(ctx.arena, jobs.Schedule{
            .hour = in.hour,
            .minute = in.minute,
            .paused = in.paused,
        }, .{}) catch return error.OutOfMemory;

        try store.settings.set(ctx.db, key, set, ctx.now_ms);
        try registry.SDK.jobs.reschedule(ctx, in.plugin, in.name);

        return .{};
    }

    fn repeats(ctx: *Ctx, plugin: []const u8, verb: []const u8) Error!bool {
        std.debug.assert(plugin.len > 0 and verb.len > 0);

        for (try registry.SDK.jobs.repeating(ctx)) |job| {
            if (std.mem.eql(u8, job.plugin, plugin) and std.mem.eql(u8, job.name, verb)) {
                return true;
            }
        }

        return false;
    }
};

pub const SetTimeZone = struct {
    pub const name = "project.set_time_zone";
    pub const description = "Choose the site's time zone";
    pub const details =
        \\Administrators only. A zone's name (`Europe/Warsaw`), `UTC` by default: repeating
        \\jobs run at their times on its clock, summer time included, and their waiting runs
        \\move to match.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        time_zone: []const u8,
    };
    pub const Out = struct {};
    pub const example: In = .{
        .time_zone = "Europe/Warsaw",
    };
    pub const example_out: Out = .{};
    pub const field_docs: sdk.operation.Docs(In) = .{
        .time_zone = "A zone's name from the time zone database, or `UTC`",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (zone.rule_of(in.time_zone) == null) {
            return error.Invalid;
        }

        try store.settings.set(ctx.db, jobs.zone_key, in.time_zone, ctx.now_ms);
        try registry.SDK.jobs.reschedule(ctx, null, "");

        return .{};
    }
};

pub const operations = [_]type{ List, RunAgain, Schedule, SetTimeZone };
