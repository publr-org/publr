const std = @import("std");
const sdk = @import("../sdk.zig");
const store = @import("../store.zig");

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
        .jobs = "Each job: its plugin and name, its input as JSON, when it is due (ms), how " ++
            "many runs failed, `waiting` or `failed`, and the last problem",
    };

    pub fn run(ctx: *Ctx, _: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        return .{
            .jobs = try store.job_queue.list(ctx.db, ctx.arena, 200),
        };
    }
};

pub const operations = [_]type{List};
