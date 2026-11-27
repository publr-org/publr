//! Core's queued work: the jobs waiting, running and done, what one answered, running one
//! again, scheduling and the site's time zone repeating jobs read.
const operation = @import("../operation.zig");

pub const namespace: operation.Namespace = .{
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
        \\ones, a page of 200 at a time: `next` continues it. Changes nothing.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        after: []const u8 = "",
    };
    pub const Out = struct {
        jobs: []const Listed,
        /// Where the next page of jobs starts; empty after the last.
        next: []const u8 = "",
        /// The jobs that run again and again, as the administrator set them.
        repeating: []const Repeating = &.{},
        /// The site's time zone, which repeating jobs' times are read in.
        time_zone: []const u8 = "UTC",
    };
    pub const Listed = struct {
        id: i64,
        plugin: []const u8,
        name: []const u8,
        input: operation.Json,
        due_at: i64,
        attempts: i64,
        state: []const u8,
        problem: []const u8,
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
            .input = .{
                .text = "{\"greeting\":\"0a1b2c3d4e5f60718293a4b5\"}",
            },
            .due_at = 1792405860000,
            .attempts = 0,
            .state = "waiting",
            .problem = "",
        }},
    };
    pub const field_docs: operation.Docs(In) = .{
        .after = "The page after this one: the `next` the last page answered",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .jobs = "Each job: its id, its plugin and name, its input, when it is due " ++
            "(ms), how many runs failed, `waiting` or `failed`, and the last problem",
        .next = "The next page's `after`; empty after the last",
        .repeating = "Each repeating job: its plugin and name, how often (`every`, " ++
            "`minutes`), the hour and minute it runs at on the site's clock, and whether " ++
            "it is paused",
        .time_zone = "The site's time zone, `UTC` unless one was chosen",
    };
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
    pub const kind: operation.Kind = .read;
    pub const open = true;
    pub const example_signed_in = true;
    pub const In = struct {
        id: []const u8,
    };
    pub const Out = struct {
        state: []const u8,
        answer: ?operation.Json = null,
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
    pub const field_docs: operation.Docs(In) = .{
        .id = "What the operation answered when it queued the work",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .state = "`waiting`, `done` or `failed`",
        .answer = "The answer, once done, as the operation describes it",
        .problem = "Why it failed",
    };
};

pub const RunAgain = struct {
    pub const name = "job.run_again";
    pub const description = "Run a failed job again";
    pub const details =
        \\Administrators only. The job waits to run at once, its tries counted afresh, as it
        \\was first queued. Refused when no failed job has that id.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        job: i64,
    };
    pub const Out = struct {};
    pub const example: In = .{
        .job = 7,
    };
    pub const example_out: Out = .{};
    pub const field_docs: operation.Docs(In) = .{
        .job = "The failed job's id, from `job.list`",
    };
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
    pub const kind: operation.Kind = .write;
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
    pub const field_docs: operation.Docs(In) = .{
        .plugin = "The job's plugin",
        .name = "The job's name, from `job.list`'s `repeating`",
        .hour = "0 to 23, on the site's clock",
        .minute = "0 to 59",
        .paused = "Run no more until set false again",
    };
};

pub const SetTimeZone = struct {
    pub const name = "project.set_time_zone";
    pub const description = "Choose the site's time zone";
    pub const details =
        \\Administrators only. A zone's name (`Europe/Warsaw`), `UTC` by default: repeating
        \\jobs run at their times on its clock, summer time included, and their waiting runs
        \\move to match.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        time_zone: []const u8,
    };
    pub const Out = struct {};
    pub const example: In = .{
        .time_zone = "Europe/Warsaw",
    };
    pub const example_out: Out = .{};
    pub const field_docs: operation.Docs(In) = .{
        .time_zone = "A zone's name from the time zone database, or `UTC`",
    };
};

pub const TimeZone = struct {
    pub const name = "project.time_zone";
    pub const open = true;
    pub const description = "The site's time zone: its name and its rule";
    pub const details =
        \\Anyone. What a plugin's `ctx.time_zone()` answers: the zone's name (`Europe/Warsaw`,
        \\`UTC` until one is chosen with `project.set_time_zone`) and its rule as a POSIX
        \\time zone string, summer time included, for reading moments on the site's clock.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        name: []const u8,
        rule: []const u8,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .name = "Europe/Warsaw",
        .rule = "CET-1CEST,M3.5.0,M10.5.0/3",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .name = "The zone's name",
        .rule = "Its rule: offsets and when summer time starts and ends",
    };
};
