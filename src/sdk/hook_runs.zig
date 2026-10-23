//! An `on` hook's failed run, kept in `job_queue` so the jobs' machinery runs it again: named
//! `on:<event>` (`on:<event>#2` for a plugin's second hook on it), the event's payload (JSON)
//! as its input.
const std = @import("std");
const job_queue = @import("../store/job_queue.zig");

pub const prefix = "on:";
/// Why a kept run cannot run: its hook is no longer there.
pub const gone = "no such hook: its plugin is gone or no longer has it";
/// A plugin's hooks on one event, at most: past it the name says nothing more.
pub const ordinal_max: u32 = 64;

pub const Target = struct {
    event: []const u8,
    ordinal: u32,
};

pub fn is_hook(job: []const u8) bool {
    std.debug.assert(job.len > 0);
    std.debug.assert(prefix.len == 3);

    return std.mem.startsWith(u8, job, prefix);
}

/// The kept run's name for a plugin's hook on `event`, by which of its hooks it is.
pub fn name_of(
    arena: std.mem.Allocator,
    event: []const u8,
    ordinal: u32,
) error{OutOfMemory}![]const u8 {
    std.debug.assert(event.len > 0);
    std.debug.assert(ordinal < ordinal_max);

    if (ordinal == 0) {
        return std.fmt.allocPrint(arena, prefix ++ "{s}", .{event});
    }

    return std.fmt.allocPrint(arena, prefix ++ "{s}#{d}", .{ event, ordinal + 1 });
}

/// The event and hook a kept run's name points at; null for a name that is not one.
pub fn target_of(job: []const u8) ?Target {
    std.debug.assert(job.len > 0);

    if (!is_hook(job) or job.len == prefix.len) {
        return null;
    }

    const rest = job[prefix.len..];
    const hash = std.mem.lastIndexOfScalar(u8, rest, '#') orelse return .{
        .event = rest,
        .ordinal = 0,
    };
    const counted = std.fmt.parseInt(u32, rest[hash + 1 ..], 10) catch return null;

    if (hash == 0 or counted < 2 or counted > ordinal_max) {
        return null;
    }

    return .{
        .event = rest[0..hash],
        .ordinal = counted - 1,
    };
}

test "a kept hook run's name goes there and back" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const first = try name_of(arena, "shop.order.placed", 0);
    const second = try name_of(arena, "shop.order.placed", 1);

    try std.testing.expectEqualStrings("on:shop.order.placed", first);
    try std.testing.expectEqualStrings("on:shop.order.placed#2", second);
    try std.testing.expectEqual(1, target_of(second).?.ordinal);
    try std.testing.expectEqualStrings("shop.order.placed", target_of(first).?.event);
    try std.testing.expect(!is_hook("release_hold"));
    try std.testing.expectEqual(null, target_of("on:"));
    try std.testing.expectEqual(null, target_of("on:x#1"));
    try std.testing.expectEqual(null, target_of("on:x#nine"));
}

const sdk = @import("../sdk.zig");
const job_define = @import("plugin/job_define.zig");

/// The hooks the test below runs: probe's first fails twice then runs, its second always
/// runs, other's always fails. Each counts its runs in a table, as the worker's State would
/// not survive a process.
const Probe = struct {
    const Out = sdk.testing.Record.Out;

    fn count(ctx: *sdk.Ctx, comptime table: []const u8) sdk.Error!u32 {
        std.debug.assert(ctx.db.transaction_depth == 0);

        try ctx.db.exec("CREATE TABLE IF NOT EXISTS " ++ table ++ " (author TEXT NOT NULL)");

        var insert = try ctx.db.prepare("INSERT INTO " ++ table ++ " (author) VALUES (?1)");
        defer insert.finalize();

        try insert.bind_text(1, ctx.job);
        try insert.exec();

        return sdk.testing.count(ctx, table);
    }

    const Flaky = struct {
        pub const stage: sdk.hooks.Stage = .on;
        pub const event = "hello.record";
        pub const Payload = Out;

        pub fn run(ctx: *sdk.Ctx, out: Payload) sdk.Error!void {
            std.debug.assert(out.rows == 1);

            if (try count(ctx, "flaky_runs") <= 2) {
                return ctx.fail(.{
                    .name = "Offline",
                    .status = 503,
                    .message = "the printer is offline",
                });
            }
        }
    };

    const Steady = struct {
        pub const stage: sdk.hooks.Stage = .on;
        pub const event = "hello.record";
        pub const Payload = Out;

        pub fn run(ctx: *sdk.Ctx, out: Payload) sdk.Error!void {
            std.debug.assert(out.rows == 1);

            _ = try count(ctx, "steady_runs");
        }
    };

    const Broken = struct {
        pub const stage: sdk.hooks.Stage = .on;
        pub const event = "hello.record";
        pub const Payload = Out;

        pub fn run(ctx: *sdk.Ctx, out: Payload) sdk.Error!void {
            std.debug.assert(out.rows == 1);

            _ = try count(ctx, "broken_runs");

            return error.Unavailable;
        }
    };

    fn activity(_: *sdk.Ctx, _: *const sdk.trail.Entry) sdk.Error!?sdk.trail.Logged {
        return null;
    }

    fn failure(_: *sdk.Ctx, _: *const sdk.trail.Entry) ?sdk.trail.Logged {
        return null;
    }

    fn lines(ctx: *sdk.Ctx, call: []const u8, said: []const sdk.trail.Line) ?sdk.trail.Logged {
        std.debug.assert(call.len > 0);

        keep(ctx, call, said) catch |err| std.debug.panic("lines not kept: {t}", .{err});

        return null;
    }

    fn keep(ctx: *sdk.Ctx, call: []const u8, said: []const sdk.trail.Line) !void {
        std.debug.assert(call.len > 0);

        try ctx.db.exec("CREATE TABLE IF NOT EXISTS logged (call TEXT, plugin TEXT, text TEXT)");

        for (said) |line| {
            var insert = try ctx.db.prepare("INSERT INTO logged VALUES (?1, ?2, ?3)");
            defer insert.finalize();

            try insert.bind_text(1, call);
            try insert.bind_text(2, line.plugin);
            try insert.bind_text(3, line.text);
            try insert.exec();
        }
    }
};

const ProbeSDK = sdk.SDK(.{
    .operations = &.{sdk.testing.Record},
    .hooks = &.{ Probe.Flaky, Probe.Steady, Probe.Broken },
    .hook_owners = &.{ "probe", "probe", "other" },
    .log = .{
        .activity = Probe.activity,
        .failure = Probe.failure,
        .lines = Probe.lines,
    },
});

test "each on hook runs again on its own, as a job, and is kept failed when tries run out" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.system);

    _ = try ProbeSDK.dispatch(&ctx, sdk.testing.Record, .{
        .note = "kept",
    });

    try std.testing.expectEqual(3, try ProbeSDK.jobs.drain(&ctx, 8));
    try std.testing.expectEqual(1, try sdk.testing.count(&ctx, "steady_runs"));

    // Flaky and Broken wait, each a run of its own; Steady is done.
    const waiting = try job_queue.list(ctx.db, ctx.arena, 8);

    try std.testing.expectEqual(2, waiting.len);
    try std.testing.expectEqualStrings("on:hello.record", waiting[0].name);
    try std.testing.expectEqualStrings("the printer is offline", waiting[0].problem);
    try std.testing.expectEqual(1, waiting[0].attempts);

    for (1..job_define.attempts_max) |_| {
        try std.testing.expectEqual(0, try ProbeSDK.jobs.drain(&ctx, 8));

        ctx.now_ms += job_define.backoff_ms_max;
        _ = try ProbeSDK.jobs.drain(&ctx, 8);
    }

    try std.testing.expectEqual(1, try sdk.testing.count(&ctx, "steady_runs"));
    try std.testing.expectEqual(3, try sdk.testing.count(&ctx, "flaky_runs"));
    try std.testing.expectEqual(
        job_define.attempts_max,
        try sdk.testing.count(&ctx, "broken_runs"),
    );

    const kept = try job_queue.list(ctx.db, ctx.arena, 8);

    try std.testing.expectEqual(1, kept.len);
    try std.testing.expectEqualStrings("other", kept[0].plugin);
    try std.testing.expectEqualStrings("on:hello.record", kept[0].name);
    try std.testing.expectEqualStrings("failed", kept[0].state);
    try std.testing.expectEqualStrings("Unavailable", kept[0].problem);
    try std.testing.expectEqual(job_define.attempts_max, kept[0].attempts);
    try std.testing.expectEqual(null, try job_queue.next_due(ctx.db));

    // The run is the author: each run wrote as `<plugin>.on:<event>`, the second hook `#2`.
    var authors = try ctx.db.prepare("SELECT author FROM steady_runs UNION ALL " ++
        "SELECT author FROM broken_runs WHERE rowid = 8");
    defer authors.finalize();

    const Author = struct {
        author: []const u8,
    };

    try std.testing.expect(try authors.step());
    try std.testing.expectEqualStrings(
        "probe.on:hello.record#2",
        (try authors.read(Author, ctx.arena)).author,
    );
    try std.testing.expect(try authors.step());
    try std.testing.expectEqualStrings(
        "other.on:hello.record",
        (try authors.read(Author, ctx.arena)).author,
    );

    // On the plugin's Log, under the event: each try, then failed for good.
    var last = try ctx.db.prepare("SELECT call, plugin, text FROM logged ORDER BY rowid DESC");
    defer last.finalize();

    try std.testing.expect(try last.step());

    const Logged = struct {
        call: []const u8,
        plugin: []const u8,
        text: []const u8,
    };
    const line = try last.read(Logged, ctx.arena);

    try std.testing.expectEqualStrings("event:hello.record", line.call);
    try std.testing.expectEqualStrings("other", line.plugin);
    try std.testing.expectEqualStrings(
        "The hook on hello.record failed for good after 8 tries: Unavailable",
        line.text,
    );
}
