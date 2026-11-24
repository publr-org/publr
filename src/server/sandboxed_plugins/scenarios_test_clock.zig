//! A test site's clock moved (`project.set_clock`), on the test plugin `sampler`: the
//! contexts a server makes read the moved time, a `.due` job waits for it and the queue's
//! tick runs it once the clock passes its moment; production and a copy refuse to move it.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../registry.zig");
const job_queue = @import("../../store/job_queue.zig");
const plugin_log = @import("../../operations/plugin/log.zig");
const clock = @import("../../operations/clock.zig");
const identity = @import("../../adapters/rest/identity.zig");
const queued_jobs = @import("../queued_jobs.zig");
const scenarios = @import("scenarios.zig");
const scenarios_remotes = @import("scenarios_remotes.zig");

const Scenario = scenarios.Scenario;
const Project = @import("../project.zig").Project;
const module = @embedFile("sandboxed_plugin_sampler");

const day_ms: i64 = 24 * 60 * 60 * 1000;
const hour_ms: i64 = 60 * 60 * 1000;

fn project_of(scenario: *Scenario) Project {
    std.debug.assert(module.len > 0);

    var project: Project = .{
        .connection = &scenario.harness.fixture.connection,
        .auth = &scenario.harness.auth,
        .io = std.testing.io,
        .sandboxed_plugins = scenario.host.sandboxed_plugins(),
    };

    // Served over plain http on this computer: development, a test site.
    project.outside.production = false;
    std.debug.assert(project.test_clock());

    return project;
}

fn set_clock(project: *const Project, in: clock.SetClock.In) !i64 {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var ctx = identity.context(project, arena_state.allocator(), .system);
    const set = try registry.SDK.dispatch(&ctx, clock.SetClock, in);

    std.debug.assert(set.now_ms >= 0);

    return set.now_ms;
}

/// How many of sampler's `remind` jobs wait.
fn reminders(ctx: *sdk.Ctx) !u32 {
    const waiting = try job_queue.list(ctx.db, ctx.arena, 16);
    var count: u32 = 0;

    std.debug.assert(waiting.len <= 16);

    for (waiting) |job| {
        if (std.mem.eql(u8, job.name, "remind")) {
            count += 1;
        }
    }

    return count;
}

fn logged(scenario: *Scenario, text: []const u8) !bool {
    var reading = scenario.ctx(.system);
    const log = try registry.SDK.dispatch(&reading, plugin_log.Log, .{
        .name = "sampler",
        .limit = 200,
    });

    std.debug.assert(text.len > 0);

    for (log.lines) |line| {
        if (std.mem.eql(u8, line.line, text)) {
            return true;
        }
    }

    return false;
}

test "a test site's clock moves: contexts read it, a .due job runs once it passes its moment" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    _ = try scenarios_remotes.put(&scenario, "sampler.wasm", module);
    try scenarios_remotes.enable(&scenario, "sampler");

    const project = project_of(&scenario);
    const wall = sdk.context.wall_clock_ms(std.testing.io);
    const moved = try set_clock(&project, .{
        .at_ms = wall + 40 * day_ms,
    });
    const arena = scenario.harness.fixed.allocator();
    var admin = identity.context(&project, arena, scenarios.admin);

    try std.testing.expectEqual(wall + 40 * day_ms, moved);
    try std.testing.expect(admin.now_ms >= moved and admin.now_ms < moved + 60_000);

    // A note to be reminded of two hours on: its job waits half an hour before, site time.
    const input = try std.fmt.allocPrint(
        arena,
        "{{\"type\":\"sampler.sample_note\",\"document\":" ++
            "{{\"note\":\"Call Ada\",\"remind_at\":{d}}}}}",
        .{moved + 2 * hour_ms},
    );

    _ = try registry.SDK.call_json(&admin, "record.create", input);

    var ticks: queued_jobs.Clock = .{};

    queued_jobs.tick(&project, std.testing.allocator, &ticks, project.now_ms());
    try std.testing.expectEqual(1, try reminders(&admin));
    try std.testing.expect(!try logged(&scenario, "job remind: Call Ada is due"));

    // Two hours on, the worker's tick reads the moved clock and runs it.
    _ = try set_clock(&project, .{
        .ahead_ms = 2 * hour_ms,
    });
    ticks = .{};
    queued_jobs.tick(&project, std.testing.allocator, &ticks, project.now_ms());
    try std.testing.expect(try logged(&scenario, "job remind: Call Ada is due"));
    try std.testing.expectEqual(0, try reminders(&admin));

    // Back on the wall clock.
    const reset = try set_clock(&project, .{
        .reset = true,
    });

    try std.testing.expect(reset < wall + day_ms);
    try std.testing.expect(project.now_ms() < wall + day_ms);
}

test "production and a copy keep the wall clock and refuse to move it" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    var project = project_of(&scenario);

    _ = try set_clock(&project, .{
        .ahead_ms = 40 * day_ms,
    });

    const wall = sdk.context.wall_clock_ms(std.testing.io);

    try std.testing.expect(project.now_ms() > wall + 39 * day_ms);

    project.on_copy = true;
    try std.testing.expect(project.now_ms() < wall + day_ms);
    try std.testing.expectError(error.Failed, set_clock(&project, .{
        .ahead_ms = day_ms,
    }));

    project.on_copy = false;
    project.outside.production = true;
    try std.testing.expect(project.now_ms() < wall + day_ms);
    try std.testing.expectError(error.Failed, set_clock(&project, .{
        .ahead_ms = day_ms,
    }));
}
