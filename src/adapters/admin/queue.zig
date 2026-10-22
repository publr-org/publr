//! Queued work, reached from the ⋯ menu beside System settings' tabs: the jobs waiting to
//! run and the ones that failed for good, each failed one with Run again.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const job = @import("../../operations/job.zig");
const activity_page = @import("activity.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const views = admin.views;

pub const back = "/admin/settings/system/queue";
pub const routes_count: u32 = 2;

pub fn register(router: anytype) void {
    std.debug.assert(router.routes_len > 0);

    router.get(back, &list);
    router.post(back ++ "/:id/run", &run_again);
}

pub fn list(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const done = admin.query_param(&session, "done") orelse "";
    const notice = if (std.mem.eql(u8, done, "again"))
        try session.translated("Queued to run again now.", .{})
    else
        "";

    try screen(&session, notice, "");
}

fn screen(session: *admin.Session, notice: []const u8, problem: []const u8) Error!void {
    std.debug.assert(session.signed_in());
    std.debug.assert(notice.len == 0 or problem.len == 0);

    const listed = registry.SDK.dispatch(&session.ctx, job.List, .{}) catch |err| {
        return admin.fail(session, err, "/admin/settings/system");
    };
    const arena = session.arena;
    const rows = try arena.alloc(views.Queue.JobsItem, listed.jobs.len);

    for (listed.jobs, rows) |item, *row| {
        const when = try activity_page.when_of(arena, item.due_at);

        row.* = .{
            .plugin = item.plugin,
            .name = item.name,
            .failed = std.mem.eql(u8, item.state, "failed"),
            .tries = @floatFromInt(item.attempts),
            .date = when.date,
            .time = when.time,
            .problem = item.problem,
            .run_action = try std.fmt.allocPrint(arena, "{s}/{d}/run", .{ back, item.id }),
        };
    }

    try admin.screen(session, .ok, views.Queue, .{
        .jobs = rows,
        .notice = notice,
        .problem = problem,
    }, .{});
}

pub fn run_again(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    const session = &post.session;
    const id_text = try admin.param(session, "id", back) orelse return;
    const id = std.fmt.parseInt(i64, id_text, 10) catch 0;

    _ = registry.SDK.dispatch(&session.ctx, job.RunAgain, .{
        .job = id,
    }) catch |err| {
        const failure = if (err == error.Failed) session.ctx.failure else null;

        return screen(session, "", if (failure) |found| found.message else @errorName(err));
    };

    try response.redirect(.see_other, back ++ "?done=again");
}

test "Queued work: a failed job listed with why, Run again queues it to run now" {
    const sdk = @import("../../sdk.zig");
    const store = @import("../../store.zig");
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
    const setup_body = "email=ada%40example.com&display_name=Ada&password=correct+horse+battery";
    _ = try flow.call("POST", "/admin/setup", setup_body);

    const connection = &harness.fixture.connection;

    try store.job_queue.push_failed(connection, .{
        .plugin = "shop",
        .name = "sync_stock",
        .input = "{}",
        .due_at_ms = 1_790_000_000_000,
        .now_ms = 1_790_000_000_000,
    }, true, "The warehouse did not answer");

    const page = try flow.call("GET", back, "");

    try std.testing.expectEqual(.ok, page.status);
    try std.testing.expect(std.mem.indexOf(u8, page.body, "sync_stock") != null);
    try std.testing.expect(std.mem.indexOf(u8, page.body, "The warehouse did not answer") != null);

    const kept = try store.job_queue.list(connection, arena, 8);
    const action = try std.fmt.allocPrint(arena, "{s}/{d}/run", .{ back, kept[0].id });
    const form = try std.fmt.allocPrint(arena, "csrf={s}", .{flow.csrf_of(page.body)});
    const ran = try flow.call("POST", action, form);

    try std.testing.expectEqual(.see_other, ran.status);
    const after = try store.job_queue.list(connection, arena, 8);

    try std.testing.expectEqualStrings("waiting", after[0].state);
}
