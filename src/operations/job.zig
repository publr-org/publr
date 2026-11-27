const std = @import("std");
const sdk = @import("../sdk.zig");
const store = @import("../store.zig");
const registry = @import("../server/registry.zig");
const jobs = @import("../sdk/jobs.zig");
const zone = @import("../lib/zone.zig");
const id = @import("../lib/id.zig");
const public = @import("../publr/operations/job.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const namespace = public.namespace;

pub const List = struct {
    pub const shape = public.List;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const Listed = shape.Listed;
    pub const Repeating = shape.Repeating;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        const from = try position_of(in.after);

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

        const page_max = sdk.operation.page_limit_max;
        const queued = try store.job_queue.list_after(ctx.db, ctx.arena, from, page_max);
        const listed = try ctx.arena.alloc(Listed, queued.len);

        for (queued, listed) |job, *shown| {
            shown.* = .{
                .id = job.id,
                .plugin = job.plugin,
                .name = job.name,
                .input = .{
                    .text = if (job.input.len > 0) job.input else "{}",
                },
                .due_at = job.due_at,
                .attempts = job.attempts,
                .state = job.state,
                .problem = job.problem,
            };
        }

        const last = if (queued.len == page_max) queued[queued.len - 1] else null;

        return .{
            .jobs = listed,
            .next = if (last) |job| std.fmt.allocPrint(ctx.arena, "{d}:{d}:{d}", .{
                @intFromBool(std.mem.eql(u8, job.state, "failed")),
                job.due_at,
                job.id,
            }) catch return error.OutOfMemory else "",
            .repeating = repeating,
            .time_zone = try store.settings.get(ctx.db, ctx.arena, jobs.zone_key) orelse "UTC",
        };
    }
};

/// `<failed 0 or 1>:<due_at>:<id>`, as `List` answers it in `next`; null for the first page.
fn position_of(after: []const u8) Error!?store.job_queue.Position {
    if (after.len == 0) {
        return null;
    }

    if (after.len > 64) {
        return error.Invalid;
    }

    std.debug.assert(after.len > 0 and after.len <= 64);

    var parts = std.mem.splitScalar(u8, after, ':');
    const failed = parts.next() orelse return error.Invalid;
    const due_at = parts.next() orelse return error.Invalid;
    const job_id = parts.next() orelse return error.Invalid;

    if (parts.next() != null or failed.len != 1 or (failed[0] != '0' and failed[0] != '1')) {
        return error.Invalid;
    }

    return .{
        .failed = failed[0] == '1',
        .due_at = std.fmt.parseInt(i64, due_at, 10) catch return error.Invalid,
        .id = std.fmt.parseInt(i64, job_id, 10) catch return error.Invalid,
    };
}

pub const Answer = struct {
    pub const shape = public.Answer;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const open = shape.open;
    pub const example_signed_in = shape.example_signed_in;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

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
    pub const shape = public.RunAgain;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

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
    pub const shape = public.Schedule;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

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
    pub const shape = public.SetTimeZone;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

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

pub const TimeZone = struct {
    pub const shape = public.TimeZone;
    pub const name = shape.name;
    pub const open = shape.open;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, _: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        const chosen = try store.settings.get(ctx.db, ctx.arena, jobs.zone_key) orelse "UTC";
        const rule = zone.rule_of(chosen) orelse "UTC0";

        return .{
            .name = chosen,
            .rule = rule,
        };
    }
};

pub const operations = [_]type{ List, Answer, RunAgain, Schedule, SetTimeZone, TimeZone };

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
        .language = ctx.language_queued(),
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
    .{ "ledger_expire", @import("ledger.zig").expire_job },
};

/// Runs core's job `name` (the worker, `registry.core_job`); answers why it failed, empty
/// when it ran.
pub fn run_core(ctx: *Ctx, name: []const u8, input: []const u8) []const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(ctx.job.len > 0);

    inline for (runs) |each| {
        if (std.mem.eql(u8, name, each[0])) {
            const In = @typeInfo(@TypeOf(each[1])).@"fn".param_types[1].?;
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
        .roles = &.{"editor"},
    });
    const bo_account = try SDK.dispatch(&admin, users.Create, .{
        .email = "bo@example.com",
        .display_name = "Bo",
        .roles = &.{"editor"},
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
