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
/// How often each repeating job is checked for a run waiting, and the trash for what is past
/// its time.
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

/// What people scheduled that is due, each made as its person, with the rights they hold
/// now: a transition, or a live record's changes published (`record.publish` with them). One
/// refused stays, failed, with why, and is not tried again.
fn transitions(project: *const Project, gpa: std.mem.Allocator, now_ms: i64) void {
    std.debug.assert(project.connection.transaction_depth == 0);
    std.debug.assert(now_ms >= 0);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const scheduled = store.scheduled_changes;
    const due = scheduled.due(project.connection, arena, now_ms, scheduled.take_max) catch |err| {
        std.log.warn("scheduled changes: not read: {t}", .{err});
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
        const name = one.transition;
        const id = one.record_id;

        if (make_scheduled(&ctx, one)) |_| {
            scheduled.made(project.connection, one.id) catch |err| {
                std.log.warn("scheduled {s} of {s} kept: {t}", .{ name, id, err });
            };
            // Made: what builds on it builds on what is live now.
            scheduled.rebase(project.connection, id, one.id, null) catch |err| {
                std.log.warn("scheduled on {s} of {s} kept: {t}", .{ name, id, err });
            };
        } else |err| {
            const problem = problem_of(arena, &ctx, err);

            std.log.warn("scheduled {s} of {s}: {s}", .{ name, id, problem });
            scheduled.failed(project.connection, one.id, problem) catch |kept| {
                std.log.warn("scheduled {s} of {s} kept: {t}", .{ name, id, kept });
            };
        }
    }
}

/// One entry made: its changes published, or its transition.
fn make_scheduled(ctx: *sdk.Ctx, one: store.scheduled_changes.Entry) anyerror!void {
    std.debug.assert(one.record_id.len > 0);
    std.debug.assert(one.id > 0);

    if (one.changes.len == 0 and one.held_back == null) {
        _ = try registry.SDK.dispatch(ctx, record.Transition, .{
            .id = one.record_id,
            .transition = one.transition,
        });

        return;
    }

    _ = try registry.SDK.dispatch(ctx, record.Publish, .{
        .id = one.record_id,
        .changes = if (one.changes.len > 0) one.changes else null,
        .held_back = one.held_back,
    });
}

/// Why a scheduled entry was refused, for people: each problem the refusal named
/// (`title@language=pl: Required in Polski`), else the error.
fn problem_of(arena: std.mem.Allocator, ctx: *const sdk.Ctx, err: anyerror) []const u8 {
    std.debug.assert(@errorName(err).len > 0);
    std.debug.assert(ctx.problems.len <= 64 << 10);

    if (ctx.problems.len == 0) {
        return @errorName(err);
    }

    var out: std.Io.Writer.Allocating = .init(arena);

    for (ctx.problems, 0..) |problem, index| {
        const lead = if (index == 0) "" else "; ";

        out.writer.print("{s}{s}: {s}", .{ lead, problem.field, problem.message }) catch {
            return @errorName(err);
        };
    }

    return out.written();
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
    _ = @import("../operations/trash.zig").sweep(&ctx) catch |err| {
        std.log.warn("trash: what is past its time not emptied: {t}", .{err});
    };
}

test "scheduled moves and changes are shown on the record, then made as their person once due" {
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

    try std.testing.expectEqualStrings("publish", shown.scheduled[0].transition);
    try std.testing.expectEqual(at, shown.scheduled[0].at);

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
    try std.testing.expectEqual(0, made.scheduled.len);

    // Live, its changes scheduled: the title kept in the entry, the pending copy cleared.
    _ = try registry.SDK.dispatch(&person, record.Save, .{
        .id = created.id,
        .document = "{\"title\":\"Deal\",\"body\":\"x\"}",
    });

    const later = at + 60_000;
    const deal = try registry.SDK.dispatch(&person, record.TransitionAt, .{
        .id = created.id,
        .transition = "publish",
        .at = later,
    });
    const parked = try registry.SDK.dispatch(&person, record.Get, .{
        .id = created.id,
        .purpose = .edit,
    });

    try std.testing.expect(deal.entry > 0);
    try std.testing.expect(!parked.record.changed);
    try std.testing.expectEqualStrings("title", parked.scheduled[0].changes[0]);

    // Meanwhile the body is fixed and published: the deal leaves it.
    _ = try registry.SDK.dispatch(&person, record.Save, .{
        .id = created.id,
        .document = "{\"title\":\"Later\",\"body\":\"fixed\"}",
    });
    _ = try registry.SDK.dispatch(&person, record.Publish, .{
        .id = created.id,
    });

    transitions(&flow.inner.project, std.testing.allocator, later);

    const after = try registry.SDK.dispatch(&person, record.Get, .{
        .id = created.id,
    });

    try std.testing.expect(std.mem.indexOf(u8, after.document, "\"title\":\"Deal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, after.document, "\"body\":\"fixed\"") != null);

    // Stacked: A sets the title on what is live; B, on top of A, puts it back. Another
    // title on what is live clashes with A. B published now takes A with it.
    _ = try registry.SDK.dispatch(&person, record.Save, .{
        .id = created.id,
        .document = "{\"title\":\"Deal 2\",\"body\":\"fixed\"}",
    });

    const first = try registry.SDK.dispatch(&person, record.TransitionAt, .{
        .id = created.id,
        .transition = "publish",
        .at = later + 60_000,
    });

    _ = try registry.SDK.dispatch(&person, record.SaveVersion, .{
        .id = created.id,
        .version = first.entry,
        .document = "{\"title\":\"Back\",\"body\":\"fixed\"}",
    });

    const second = try registry.SDK.dispatch(&person, record.TransitionAt, .{
        .id = created.id,
        .transition = "publish",
        .at = later + 120_000,
        .base = first.entry,
    });
    const as_first = try registry.SDK.dispatch(&person, record.Get, .{
        .id = created.id,
        .purpose = .edit,
        .version = first.entry,
    });
    const as_second = try registry.SDK.dispatch(&person, record.Get, .{
        .id = created.id,
        .purpose = .edit,
        .version = second.entry,
    });

    try std.testing.expect(std.mem.indexOf(u8, as_first.document, "Deal 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, as_second.document, "\"title\":\"Back\"") != null);

    _ = try registry.SDK.dispatch(&person, record.Save, .{
        .id = created.id,
        .document = "{\"title\":\"Clash\",\"body\":\"fixed\"}",
    });
    const clashing = registry.SDK.dispatch(&person, record.TransitionAt, .{
        .id = created.id,
        .transition = "publish",
        .at = later + 90_000,
    });

    try std.testing.expectError(error.Invalid, clashing);
    _ = try registry.SDK.dispatch(&person, record.DiscardChanges, .{
        .id = created.id,
    });

    _ = try registry.SDK.dispatch(&person, record.PublishVersion, .{
        .id = created.id,
        .version = second.entry,
    });

    const squashed = try registry.SDK.dispatch(&person, record.Get, .{
        .id = created.id,
        .purpose = .edit,
    });

    try std.testing.expect(std.mem.indexOf(u8, squashed.document, "\"title\":\"Back\"") != null);
    try std.testing.expectEqual(0, squashed.scheduled.len);
}
