//! An installed plugin's queued work that core starts, on the test plugin `sampler`: a `.due`
//! job queued by a write to its record and run at its moment with the record, and a webhook's
//! delivery checked, kept and run in its sandbox.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const http = @import("../../lib/http.zig");
const registry = @import("../registry.zig");
const store = @import("../../store.zig");
const job_queue = @import("../../store/job_queue.zig");
const plugin_log = @import("../../operations/plugin/log.zig");
const webhooks = @import("../../adapters/rest/webhooks.zig");
const scenarios = @import("scenarios.zig");
const scenarios_remotes = @import("scenarios_remotes.zig");

const Scenario = scenarios.Scenario;
const Project = @import("../project.zig").Project;
const admin = scenarios.admin;
const module = @embedFile("sandboxed_plugin_sampler");

/// Sampler added and enabled.
fn install(scenario: *Scenario) !void {
    std.debug.assert(module.len > 0);

    _ = try scenarios_remotes.put(scenario, "sampler.wasm", module);
    try scenarios_remotes.enable(scenario, "sampler");
}

/// Whether one of sampler's Log lines says `text`.
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

test "an installed plugin's .due job is queued by its record's write and runs at its moment" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    try install(&scenario);

    const now = scenario.ctx(.system).now_ms;
    const hour_ms: i64 = 60 * 60 * 1000;
    const arena = scenario.harness.fixed.allocator();
    const input = try std.fmt.allocPrint(
        arena,
        "{{\"type\":\"sampler.sample_note\",\"document\":" ++
            "\"{{\\\"note\\\":\\\"Call Ada\\\",\\\"remind_at\\\":{d}}}\"}}",
        .{now + 2 * hour_ms},
    );

    _ = try scenario.call(admin, "record.create", input);

    // Half an hour before the note's time, and not before.
    var worker = scenario.ctx(.system);
    const waiting = try job_queue.list(worker.db, worker.arena, 8);

    try std.testing.expectEqual(1, waiting.len);
    try std.testing.expectEqualStrings("sampler", waiting[0].plugin);
    try std.testing.expectEqualStrings("remind", waiting[0].name);
    try std.testing.expectEqual(now + 2 * hour_ms - 30 * 60 * 1000, waiting[0].due_at);
    try std.testing.expectEqual(0, try registry.SDK.jobs.drain(&worker, 8));

    worker.now_ms = waiting[0].due_at;
    try std.testing.expectEqual(1, try registry.SDK.jobs.drain(&worker, 8));
    try std.testing.expect(try logged(&scenario, "job remind: Call Ada is due"));
    try std.testing.expectEqual(0, (try job_queue.list(worker.db, worker.arena, 8)).len);
}

test "an installed plugin's webhook: a signed delivery runs in its sandbox, once" {
    const Environment = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    };

    try std.testing.expectEqual(0, Environment.setenv("SAMPLER_KEY", "s4mpler", 1));
    defer _ = Environment.unsetenv("SAMPLER_KEY");

    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    try install(&scenario);

    var project: Project = .{
        .connection = &scenario.harness.fixture.connection,
        .auth = &scenario.harness.auth,
        .io = std.testing.io,
        .sandboxed_plugins = scenario.host.sandboxed_plugins(),
    };
    var app = http.App.offline(.{});
    app.user_data = &project;
    webhooks.Receive(&.{}, &.{}).register(app.router());

    const arena = scenario.harness.fixed.allocator();
    const body = "{\"id\":\"d1\",\"text\":\"Hello\"}";
    const signed = "POST /_webhooks/sampler.ping HTTP/1.1\r\nHost: h\r\n" ++
        "X-Sampler-Key: s4mpler\r\nContent-Length: 26\r\n\r\n";
    const forged = "POST /_webhooks/sampler.ping HTTP/1.1\r\nHost: h\r\n" ++
        "X-Sampler-Key: guess\r\nContent-Length: 26\r\n\r\n";

    try std.testing.expectEqual(200, (try send(&app, arena, signed, body)).status.code());
    try std.testing.expectEqual(200, (try send(&app, arena, signed, body)).status.code());
    try std.testing.expectEqual(401, (try send(&app, arena, forged, body)).status.code());

    // One run queued, the repeat dropped: it runs in the sandbox with the body as its event.
    var worker = scenario.ctx(.system);

    worker.now_ms = sdk.context.wall_clock_ms(std.testing.io) + 1000;
    try std.testing.expectEqual(1, try registry.SDK.jobs.drain(&worker, 8));
    try std.testing.expectEqual(0, try registry.SDK.jobs.drain(&worker, 8));

    const listed = try store.webhook_deliveries.list(worker.db, arena, "sampler", 8);

    try std.testing.expectEqual(2, listed.len);
    try std.testing.expectEqualStrings("refused", listed[0].result);
    try std.testing.expectEqualStrings("ran", listed[1].result);
    try std.testing.expect(try logged(&scenario, "webhook ping: Hello"));
}

fn send(
    app: *http.App,
    arena: std.mem.Allocator,
    head: []const u8,
    body: []const u8,
) !http.Response {
    std.debug.assert(head.len > 0);

    const parsed = try http.parse(head);
    const wire = parsed.complete;
    var request: http.Request = .{
        .inner = &wire,
        .body = body,
    };

    return app.handle(arena, &request);
}
