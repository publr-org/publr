const std = @import("std");
const sdk = @import("../sdk.zig");
const store = @import("../store.zig");
const registry = @import("../server/registry.zig");
const jobs = @import("../sdk/jobs.zig");
const zone = @import("../lib/zone.zig");
const id = @import("../lib/id.zig");

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
    \\Core's own outside work (a download, a model's answer) is queued as `publr`'s: what
    \\someone waits on answers at once with an id, and `job answer` reads what landed.
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

pub const Answer = struct {
    pub const name = "job.answer";
    pub const description = "What queued work someone waits on answered, once it lands";
    pub const details =
        \\An operation that needs another server (a download, a model's answer) answers at
        \\once with an id and queues the work; this reads it: `waiting` until it lands, then
        \\`done` with the answer, or `failed` with why. Only whoever asked reads it; kept a
        \\day.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const open = true;
    pub const example_signed_in = true;
    pub const In = struct {
        id: []const u8,
    };
    pub const Out = struct {
        state: []const u8,
        answer: ?sdk.operation.Json = null,
        problem: []const u8 = "",
    };
    pub const example: In = .{
        .id = "6a1f0c2e9b3d4a5f60718293",
    };
    pub const example_out: Out = .{
        .state = "done",
        .answer = .{
            .text = "{\"ok\":true,\"reply\":\"OK\"}",
        },
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "What the operation answered when it queued the work",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .state = "`waiting`, `done` or `failed`",
        .answer = "The answer, once done, as the operation describes it",
        .problem = "Why it failed",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        if (in.id.len != id.len) {
            return error.Invalid;
        }

        const kept = try kept_of(ctx, in.id) orelse return error.NotFound;
        const own = if (ctx.caller.user_id()) |user| std.mem.eql(u8, user, kept.by) else false;

        if (ctx.caller != .system and !own) {
            return error.NotFound;
        }

        return .{
            .state = kept.state,
            .answer = kept.answer,
            .problem = kept.problem,
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

pub const operations = [_]type{ List, Answer, RunAgain, Schedule, SetTimeZone };

/// Who owns core's own queued work on the job queue.
pub const core = store.job_queue.core;

/// How long an answer is kept after it was asked for.
const answer_keep_ms: i64 = 24 * 60 * 60 * 1000;
/// Where answers are kept: core's own internal records, one per id asked.
const answers: store.internal_records.Scope = .{
    .plugin = core,
    .app = "",
    .kind = "job_answer",
};

/// An answer as kept, the record's id the id asked.
const Kept = struct {
    /// The user who asked; empty for the system.
    by: []const u8 = "",
    state: []const u8,
    answer: ?sdk.operation.Json = null,
    problem: []const u8 = "",
};

/// Queues core's job `name` with `input`, to run as soon as the worker gets to it.
pub fn enqueue(ctx: *Ctx, name: []const u8, input: anytype) Error!void {
    return enqueue_at(ctx, name, input, ctx.now_ms);
}

/// `enqueue`, never run before `due_at_ms`.
pub fn enqueue_at(ctx: *Ctx, name: []const u8, input: anytype, due_at_ms: i64) Error!void {
    std.debug.assert(name.len > 0);
    std.debug.assert(due_at_ms >= ctx.now_ms);

    const text = std.json.Stringify.valueAlloc(ctx.arena, input, .{}) catch {
        return error.OutOfMemory;
    };

    if (text.len > store.job_queue.input_bytes_max) {
        return error.Invalid;
    }

    try store.job_queue.push(ctx.db, .{
        .plugin = core,
        .name = name,
        .input = text,
        .due_at_ms = due_at_ms,
        .now_ms = ctx.now_ms,
    });
}

/// Queues work someone waits on: `input.asked` is set to a new id, kept `waiting` until the
/// job answers it (`answer`, `fail`). Answers the id, for `job.answer`.
pub fn ask(ctx: *Ctx, name: []const u8, input: anytype) Error![]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    var buffer: [id.len]u8 = undefined;
    const asked = ctx.arena.dupe(u8, id.random(ctx.io, &buffer)) catch return error.OutOfMemory;
    var given = input;

    given.asked = asked;

    try store.internal_records.delete_before(ctx.db, answers, ctx.now_ms - answer_keep_ms);
    try keep(ctx, asked, .{
        .by = ctx.caller.user_id() orelse "",
        .state = "waiting",
    });
    try enqueue(ctx, name, given);

    return asked;
}

/// The job's answer to `asked`: what `job.answer` gives whoever asked.
pub fn answer(ctx: *Ctx, asked: []const u8, value: anytype) Error!void {
    std.debug.assert(asked.len == id.len);

    const text = std.json.Stringify.valueAlloc(ctx.arena, value, .{}) catch {
        return error.OutOfMemory;
    };

    try keep(ctx, asked, .{
        .by = try by_of(ctx, asked),
        .state = "done",
        .answer = .{
            .text = text,
        },
    });
}

/// The job could not answer `asked`: why, in words for whoever asked.
pub fn fail(ctx: *Ctx, asked: []const u8, problem: []const u8) Error!void {
    std.debug.assert(asked.len == id.len);
    std.debug.assert(problem.len > 0);

    try keep(ctx, asked, .{
        .by = try by_of(ctx, asked),
        .state = "failed",
        .problem = problem,
    });
}

/// Why `err` failed, in the failure's own words when it gave any.
pub fn problem_of(ctx: *Ctx, err: anyerror) []const u8 {
    std.debug.assert(@errorName(err).len > 0);

    const said = if (ctx.failure) |failure| failure.message else @errorName(err);

    ctx.failure = null;

    return said;
}

fn by_of(ctx: *Ctx, asked: []const u8) Error![]const u8 {
    std.debug.assert(asked.len == id.len);

    return if (try kept_of(ctx, asked)) |kept| kept.by else "";
}

fn keep(ctx: *Ctx, asked: []const u8, kept: Kept) Error!void {
    std.debug.assert(asked.len == id.len);
    std.debug.assert(kept.state.len > 0);

    const text = std.json.Stringify.valueAlloc(ctx.arena, kept, .{
        .emit_null_optional_fields = false,
    }) catch return error.OutOfMemory;

    if (text.len > @import("../model.zig").internal_record.document_bytes_max) {
        return keep(ctx, asked, .{
            .by = kept.by,
            .state = "failed",
            .problem = "The answer is too large to keep",
        });
    }

    if (try store.internal_records.get(ctx.db, ctx.arena, answers, asked) == null) {
        return store.internal_records.insert_as(ctx.db, answers, asked, text, ctx.now_ms);
    }

    _ = try store.internal_records.update(ctx.db, answers, asked, text, null, ctx.now_ms);
}

fn kept_of(ctx: *Ctx, asked: []const u8) Error!?Kept {
    std.debug.assert(asked.len == id.len);

    const row = try store.internal_records.get(ctx.db, ctx.arena, answers, asked) orelse
        return null;

    if (row.created_at < ctx.now_ms - answer_keep_ms) {
        return null;
    }

    return std.json.parseFromSliceLeaky(Kept, ctx.arena, row.document, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch null;
}

/// Core's jobs by name: each reads its input as JSON, and answers whoever asked itself.
const runs = .{
    .{ "ai_catalog", @import("ai/catalog.zig").refresh },
    .{ "install", @import("plugin/market.zig").install_job },
    .{ "ai_test", @import("ai/setup.zig").test_job },
    .{ "find", @import("plugin/market.zig").find_job },
    .{ "find_wait", @import("plugin/market.zig").wait_job },
    .{ "media_import", @import("media/import.zig").import_job },
    .{ "transcribe", @import("ai/speech.zig").transcribe_job },
};

/// Runs core's job `name` (the worker, `registry.core_job`); answers why it failed, empty
/// when it ran.
pub fn run_core(ctx: *Ctx, name: []const u8, input: []const u8) []const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(ctx.job.len > 0);

    inline for (runs) |each| {
        if (std.mem.eql(u8, name, each[0])) {
            const In = @typeInfo(@TypeOf(each[1])).@"fn".params[1].type.?;
            const given = std.json.parseFromSliceLeaky(In, ctx.arena, input, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            }) catch return "its input no longer reads as the job's";

            each[1](ctx, given) catch |err| return problem_of(ctx, err);

            return "";
        }
    }

    return "no such job in this Publr";
}

test "work waited on: waiting until its job answers, read only by who asked, kept a day" {
    const SDK = @import("../server/registry.zig").SDK;
    const users = @import("user.zig");
    const setup = @import("ai/setup.zig");
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);

    var admin = harness.ctx(.{
        .user = .{
            .id = "u_admin",
            .roles = &.{"admin"},
        },
    });
    const ada_account = try SDK.dispatch(&admin, users.Create, .{
        .email = "ada@example.com",
        .display_name = "Ada",
    });
    const bo_account = try SDK.dispatch(&admin, users.Create, .{
        .email = "bo@example.com",
        .display_name = "Bo",
    });
    var ada = harness.ctx(.{
        .user = .{
            .id = ada_account.user_id,
            .roles = &.{"admin"},
        },
    });
    var bo = harness.ctx(.{
        .user = .{
            .id = bo_account.user_id,
            .roles = &.{"admin"},
        },
    });

    const asked = try ask(&ada, "ai_test", setup.Testing{
        .provider = "ai_example",
    });

    // Queued as core's own, on the one job queue.
    try std.testing.expect(try store.job_queue.waiting_for(ada.db, core, "ai_test"));

    const waiting = try SDK.dispatch(&ada, Answer, .{
        .id = asked,
    });

    try std.testing.expectEqualStrings("waiting", waiting.state);
    try std.testing.expectError(error.NotFound, SDK.dispatch(&bo, Answer, .{
        .id = asked,
    }));

    try answer(&system, asked, setup.Tested{
        .ok = true,
        .reply = "OK",
    });

    const done = try SDK.dispatch(&ada, Answer, .{
        .id = asked,
    });

    try std.testing.expectEqualStrings("done", done.state);
    try std.testing.expectEqualStrings("{\"ok\":true,\"reply\":\"OK\"}", done.answer.?.text);

    // Bookkeeping, as core's own internal record, kept a day.
    const kept = try store.internal_records.get(ada.db, ada.arena, answers, asked);

    try std.testing.expect(kept != null);

    ada.now_ms += answer_keep_ms + 1;
    try std.testing.expectError(error.NotFound, SDK.dispatch(&ada, Answer, .{
        .id = asked,
    }));
}
