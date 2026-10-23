const std = @import("std");
const sdk = @import("../sdk.zig");
const store = @import("../store.zig");
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
    };

    pub fn run(ctx: *Ctx, _: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        return .{
            .jobs = try store.job_queue.list(ctx.db, ctx.arena, 200),
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

pub const operations = [_]type{ List, RunAgain, Answer };

/// Who owns core's own queued work on the job queue.
pub const core = store.job_queue.core;

/// How long an answer is kept after it was asked for.
const answer_keep_ms: i64 = 24 * 60 * 60 * 1000;
const answer_prefix = "job.answer.";

/// An answer as kept, under `job.answer.<id>`.
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

    try store.settings.delete_before(ctx.db, answer_prefix, ctx.now_ms - answer_keep_ms);
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

    const key = std.fmt.allocPrint(ctx.arena, answer_prefix ++ "{s}", .{asked}) catch {
        return error.OutOfMemory;
    };
    const text = std.json.Stringify.valueAlloc(ctx.arena, kept, .{
        .emit_null_optional_fields = false,
    }) catch return error.OutOfMemory;

    if (text.len > store.settings.value_len_max) {
        return keep(ctx, asked, .{
            .by = kept.by,
            .state = "failed",
            .problem = "The answer is too large to keep",
        });
    }

    try store.settings.set(ctx.db, key, text, ctx.now_ms);
}

fn kept_of(ctx: *Ctx, asked: []const u8) Error!?Kept {
    std.debug.assert(asked.len == id.len);

    const key = std.fmt.allocPrint(ctx.arena, answer_prefix ++ "{s}", .{asked}) catch {
        return error.OutOfMemory;
    };
    const text = try store.settings.get(ctx.db, ctx.arena, key) orelse return null;

    return std.json.parseFromSliceLeaky(Kept, ctx.arena, text, .{
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

test "work someone waits on: waiting until its job answers it, read only by who asked" {
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
}
