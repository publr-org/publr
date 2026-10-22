//! Between requests, the due jobs plugins queued, and the `on` hook runs kept to run again,
//! are run (`sdk/jobs.zig`): a few a tick, so a request never waits long behind them.
const std = @import("std");
const registry = @import("registry.zig");
const job_queue = @import("../store/job_queue.zig");
const identity = @import("../adapters/rest/identity.zig");
const sdk = @import("../sdk.zig");
const store = @import("../store.zig");
const record = @import("../operations/record.zig");

const Project = @import("project.zig").Project;

/// How often the queue is looked at when nothing is due sooner.
pub const look_ms: i64 = 1000;
/// How often each repeating job is checked for a run waiting.
pub const repeat_ms: i64 = 60 * 1000;

pub const Clock = struct {
    /// When the queue is next looked at: at once on start, so due work runs after a restart.
    next_ms: i64 = 0,
    /// When the repeating jobs are next checked: at once on start.
    repeat_next_ms: i64 = 0,
};

pub fn tick(project: *const Project, gpa: std.mem.Allocator, clock: *Clock, now_ms: i64) void {
    std.debug.assert(project.connection.transaction_depth == 0);
    std.debug.assert(now_ms >= 0);

    // Kept `on` hook runs and installed plugins' jobs wait here too, whatever is compiled in.
    if (now_ms < clock.next_ms) {
        return;
    }

    clock.next_ms = now_ms + look_ms;

    if (now_ms >= clock.repeat_next_ms) {
        clock.repeat_next_ms = now_ms + repeat_ms;
        repeat(project, gpa);
    }

    transitions(project, gpa, now_ms);

    const due = job_queue.next_due(project.connection) catch |err| {
        std.log.warn("jobs: queue not read: {t}", .{err});
        return;
    };

    if (due == null or due.? > now_ms) {
        return;
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var ctx = identity.context(project, arena_state.allocator(), .system);

    const ran = registry.SDK.jobs.drain(&ctx, job_queue.take_max) catch |err| blk: {
        std.log.warn("jobs: not run: {t}", .{err});
        break :blk 0;
    };

    // A full pass leaves more due: the next tick takes them up without waiting.
    if (ran == job_queue.take_max) {
        clock.next_ms = now_ms;
    }
}

/// The transitions people scheduled that are due, each made as its person, with the rights
/// they hold now; one refused is logged as their call is and not tried again.
fn transitions(project: *const Project, gpa: std.mem.Allocator, now_ms: i64) void {
    std.debug.assert(project.connection.transaction_depth == 0);
    std.debug.assert(now_ms >= 0);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const scheduled = store.scheduled_transitions;
    const due = scheduled.due(project.connection, arena, now_ms, scheduled.take_max) catch |err| {
        std.log.warn("scheduled transitions: not read: {t}", .{err});
        return;
    };

    for (due) |one| {
        const found = store.users.find_by_id(project.connection, arena, one.scheduled_by) catch
            null;
        const caller: sdk.Caller = if (found) |person| .{
            .user = .{
                .id = person.user.id,
                .roles = person.user.roles,
            },
        } else .anonymous;
        var ctx = identity.context(project, arena, caller);

        _ = registry.SDK.dispatch(&ctx, record.Transition, .{
            .id = one.record_id,
            .transition = one.transition,
        }) catch |err| {
            std.log.warn("scheduled {s} of {s}: {t}", .{ one.transition, one.record_id, err });
        };

        scheduled.made(project.connection, one) catch |err| {
            std.log.warn("scheduled {s} of {s} kept: {t}", .{ one.transition, one.record_id, err });
        };
    }
}

fn repeat(project: *const Project, gpa: std.mem.Allocator) void {
    std.debug.assert(project.connection.transaction_depth == 0);
    std.debug.assert(repeat_ms > look_ms);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var ctx = identity.context(project, arena_state.allocator(), .system);

    _ = registry.SDK.jobs.repeat(&ctx) catch |err| {
        std.log.warn("jobs: repeating ones not queued: {t}", .{err});
    };
}

test "a scheduled transition is shown on the record, then made as its person once due" {
    const admin = @import("../adapters/admin.zig");
    const fixture = @import("../operations/record/fixture.zig");
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var flow: admin.Flow = .{
        .inner = undefined,
    };
    flow.inner.init(.{
        .connection = &harness.fixture.connection,
        .auth = &harness.auth,
        .io = std.testing.io,
    }, arena);

    var system = harness.ctx(.system);
    try registry.SDK.bootstrap(&system);
    try fixture.post_type(&system);
    const setup_body = "email=ada%40example.com&display_name=Ada&password=correct+horse+battery";
    _ = try flow.call("POST", "/admin/setup", setup_body);

    const connection = &harness.fixture.connection;
    const ada = (try store.users.find_by_email(connection, arena, "ada@example.com")).?;
    var person = harness.ctx(.{
        .user = .{
            .id = ada.user.id,
            .roles = ada.user.roles,
        },
    });
    const created = try registry.SDK.dispatch(&person, record.Create, .{
        .type = "post",
        .document = "{\"title\":\"Later\",\"body\":\"x\"}",
    });
    const at = person.now_ms + 60_000;

    _ = try registry.SDK.dispatch(&person, record.TransitionAt, .{
        .id = created.id,
        .transition = "publish",
        .at = at,
    });

    const shown = try registry.SDK.dispatch(&person, record.Get, .{
        .id = created.id,
        .purpose = .edit,
    });

    try std.testing.expectEqualStrings("publish", shown.scheduled.?.transition);
    try std.testing.expectEqual(at, shown.scheduled.?.at);

    // Nobody else's rights are kept for later: only a person schedules.
    try std.testing.expectError(error.Denied, registry.SDK.dispatch(&system, record.TransitionAt, .{
        .id = created.id,
        .transition = "publish",
        .at = at,
    }));

    transitions(&flow.inner.project, std.testing.allocator, at - 1);
    try std.testing.expectEqualStrings("draft", (try registry.SDK.dispatch(&person, record.Get, .{
        .id = created.id,
    })).record.status);

    transitions(&flow.inner.project, std.testing.allocator, at);

    const made = try registry.SDK.dispatch(&person, record.Get, .{
        .id = created.id,
        .purpose = .edit,
    });

    try std.testing.expectEqualStrings("published", made.record.status);
    try std.testing.expectEqual(null, made.scheduled);
}
