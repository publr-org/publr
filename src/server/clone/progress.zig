//! `publr clone` seen while it runs: a small server on the folder's admin address draws the
//! progress page (`/admin/sync`) and answers where the clone is (`/admin/sync/progress`) until
//! the site is here, then gives the address to the site's own server. It draws the admin's
//! own page with the admin's own files, and needs no site: there is none yet.
const std = @import("std");
const http = @import("../../lib/http.zig");
const admin = @import("../../adapters/admin.zig");
const bundle = @import("../bundle.zig");
const clock = @import("../../sdk.zig").context;

pub const page_path = "/admin/sync";
const progress_path = "/admin/sync/progress";
/// Where the page says what comes down: `?media=all` or `?media=none`.
pub const choose_path = "/admin/sync/choose";
/// Where the page takes its session once the site is here: answered once.
pub const enter_path = "/admin/sync/enter";
const tick_ms: u32 = 100;
const routes_max: u32 = admin.page_asset_routes_count + 5;

pub const Phase = enum(u8) {
    /// Waiting for the person to choose, on the page, what comes down.
    choosing,
    packing,
    downloading,
    unpacking,
    placeholders,
    starting,
    failed,
};

/// What the clone tells the page. Numbers move while the clone runs; `problem` and `sign_in`
/// are written before the phase that shows them, which publishes them.
pub const Shared = struct {
    io: std.Io,
    site: []const u8,
    folder: []const u8,
    /// The site's short name (`test-m964yr`), for the page's title.
    name: []const u8 = "",
    media: bool,
    phase: std.atomic.Value(u8) = .init(@intFromEnum(Phase.packing)),
    /// What the site weighs, for the choice; set before `choosing`.
    size: @import("site.zig").Size = .{
        .database_bytes = 0,
        .media_files = 0,
        .media_bytes = 0,
    },
    /// The choice made on the page: 1 everything, 2 without media; 0 not yet.
    chosen: std.atomic.Value(u8) = .init(0),
    /// How far the site is packing it, in ten-thousandths.
    packed_through: std.atomic.Value(u32) = .init(0),
    done_bytes: std.atomic.Value(u64) = .init(0),
    total_bytes: std.atomic.Value(u64) = .init(0),
    placeholders: std.atomic.Value(u32) = .init(0),
    /// Bytes written into the folder while unpacking, of the parts' whole.
    unpacked_bytes: std.atomic.Value(u64) = .init(0),
    started_ms: std.atomic.Value(i64) = .init(0),
    now_ms: std.atomic.Value(i64) = .init(0),
    /// When the clone began (once chosen, when the page asks), for the time it has taken.
    began_ms: i64 = 0,
    /// What the download is made of; set before `downloading`.
    parts: bundle.Parts = .{},
    problem: []const u8 = "",
    /// The cookies `enter_path` gives, once; set before `starting`.
    session_cookie: []const u8 = "",
    hint_cookie: []const u8 = "",
    entered: std.atomic.Value(bool) = .init(false),

    pub fn enter(shared: *Shared, phase: Phase) void {
        std.debug.assert(@intFromEnum(phase) >= shared.phase.load(.acquire) or phase == .failed);

        shared.phase.store(@intFromEnum(phase), .release);
    }

    pub fn fail(shared: *Shared, problem: []const u8) void {
        std.debug.assert(problem.len > 0);

        shared.problem = problem;
        shared.enter(.failed);
    }
};

pub const Server = struct {
    app: http.App,
    thread: std.Thread,
    stopping: std.atomic.Value(bool) = .init(false),
    port: u16,

    /// Listening on `port` of this machine (a free one when 0), on a thread of its own.
    pub fn start(server: *Server, gpa: std.mem.Allocator, shared: *Shared, port: u16) !void {
        std.debug.assert(shared.site.len > 0);

        server.* = .{
            .app = try http.App.init(gpa, .{
                .address = .{ 127, 0, 0, 1 },
                .port = port,
                .connections_max = 16,
                .request_bytes_max = 16 << 10,
                .response_bytes_max = 2 << 20,
                .arena_bytes = 2 << 20,
            }),
            .thread = undefined,
            .port = 0,
        };
        errdefer server.app.deinit();

        server.app.user_data = shared;

        const router = server.app.router();

        std.debug.assert(router.routes.len >= routes_max);
        admin.register_page_assets(router);
        router.get(page_path, &page);
        router.get(progress_path, &progress);
        router.post(enter_path, &enter);
        router.post(choose_path, &choose);
        router.get("/", &to_page);

        server.port = try server.app.bound_port();
        server.thread = try std.Thread.spawn(.{}, loop, .{server});
    }

    /// Stops answering and gives the port back, so the site's server can take it.
    pub fn stop(server: *Server) void {
        std.debug.assert(server.port > 0);

        server.stopping.store(true, .release);
        server.thread.join();
        server.app.deinit();
    }

    fn loop(server: *Server) void {
        std.debug.assert(tick_ms > 0);

        while (server.app.engine.phase != .stopped) {
            server.app.engine.tick(tick_ms) catch |err| {
                std.log.warn("clone progress: {t}", .{err});
                return;
            };

            if (server.stopping.load(.acquire) and server.app.engine.phase == .running) {
                server.app.engine.stop();
            }
        }
    }
};

fn shared_of(ctx: *http.Context) *Shared {
    std.debug.assert(ctx.user_data != null);

    return @ptrCast(@alignCast(ctx.user_data.?));
}

fn page(_: *http.Request, response: *http.Response, ctx: *http.Context) http.Error!void {
    const shared = shared_of(ctx);

    std.debug.assert(shared.folder.len > 0);

    const View = admin.views.CloneProgress;

    try admin.render.page(response, ctx.arena, &admin.chrome.signed_out, .ok, View, .{
        .name = shared.name,
        .folder = shown_folder(shared.folder),
        .marks_all = try marks_of(View.Marks_allItem, ctx.arena, shared.size, true),
        .marks_setup = try marks_of(View.Marks_setupItem, ctx.arena, shared.size, false),
    });
}

fn to_page(_: *http.Request, response: *http.Response, ctx: *http.Context) http.Error!void {
    std.debug.assert(ctx.user_data != null);

    try response.redirect(.see_other, page_path);
}

fn progress(_: *http.Request, response: *http.Response, ctx: *http.Context) http.Error!void {
    const shared = shared_of(ctx);

    std.debug.assert(shared.site.len > 0);

    const phase: Phase = @enumFromInt(shared.phase.load(.acquire));
    const done = shared.done_bytes.load(.acquire);
    const started = shared.started_ms.load(.acquire);
    const now = shared.now_ms.load(.acquire);
    const elapsed_ms: u64 = if (started > 0 and now > started) @intCast(now - started) else 0;
    const speed = if (elapsed_ms > 0) done * std.time.ms_per_s / elapsed_ms else 0;

    try response.set_header("Cache-Control", "no-store");
    try response.json(.ok, .{
        .phase = @tagName(phase),
        .packed_through = shared.packed_through.load(.acquire),
        .done_bytes = done,
        .total_bytes = shared.total_bytes.load(.acquire),
        .bytes_per_s = speed,
        .placeholders = shared.placeholders.load(.acquire),
        .unpacked_bytes = shared.unpacked_bytes.load(.acquire),
        .elapsed_ms = if (phase == .choosing) 0 else since_began_ms(shared),
        .parts = if (phase == .packing) bundle.Parts{} else shared.parts,
        .media = shared.media,
        .size = shared.size,
        .problem = if (phase == .failed) shared.problem else "",
        .sign_in = if (phase == .starting and shared.session_cookie.len > 0) enter_path else "",
    });
}

/// `POST /admin/sync/enter`: the clone's session, to the first page that asks once the site
/// is here; nothing to anyone after.
fn enter(_: *http.Request, response: *http.Response, ctx: *http.Context) http.Error!void {
    const shared = shared_of(ctx);
    const ready = @as(Phase, @enumFromInt(shared.phase.load(.acquire))) == .starting;

    if (!ready or shared.session_cookie.len == 0 or shared.entered.swap(true, .acq_rel)) {
        return response.json(.conflict, .{
            .@"error" = "already_entered",
        });
    }

    std.debug.assert(shared.hint_cookie.len > 0);

    try response.set_header("Cache-Control", "no-store");
    try response.set_header("Set-Cookie", shared.session_cookie);
    try response.add_header("Set-Cookie", shared.hint_cookie);
    try response.json(.ok, .{
        .entered = true,
    });
}

/// `POST /admin/sync/choose?media=all|none`: what comes down, while the clone waits for it.
fn choose(request: *http.Request, response: *http.Response, ctx: *http.Context) http.Error!void {
    const shared = shared_of(ctx);
    const waiting = @as(Phase, @enumFromInt(shared.phase.load(.acquire))) == .choosing;
    const asked = http.Form.query_param(ctx.arena, request.query(), "media") orelse "";
    const choice: u8 = if (std.mem.eql(u8, asked, "all"))
        1
    else if (std.mem.eql(u8, asked, "none"))
        2
    else
        0;

    if (!waiting or choice == 0) {
        return response.json(.conflict, .{
            .@"error" = "not_choosing",
        });
    }

    std.debug.assert(choice == 1 or choice == 2);

    shared.chosen.store(choice, .release);
    try response.json(.ok, .{
        .chosen = asked,
    });
}

/// The folder as the page names it: its last two names (`clone-test/shop`), enough to know it.
fn shown_folder(folder: []const u8) []const u8 {
    std.debug.assert(folder.len > 0);

    const trimmed = std.mem.trimEnd(u8, folder, "/");
    const last = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return trimmed;
    const before = std.mem.lastIndexOfScalar(u8, trimmed[0..last], '/') orelse return trimmed;

    return trimmed[before + 1 ..];
}

test "the page names a folder by its last two names" {
    const folder = "/Users/ada/clone-test/shop";

    try std.testing.expectEqualStrings("clone-test/shop", shown_folder(folder));
    try std.testing.expectEqualStrings("shop", shown_folder("shop"));
}

/// The bar's parts as the site weighs them, in order (database, media when it comes, apps,
/// plugins): each where it starts and its share of the bar, every part at least
/// `share_min_percent` wide so its name can be read, the rest shared by weight. None for a
/// site that did not say.
fn marks_of(
    comptime Mark: type,
    arena: std.mem.Allocator,
    size: @import("site.zig").Size,
    media: bool,
) ![]const Mark {
    const parts = [_]struct {
        []const u8,
        u64,
    }{
        .{ "Database", size.database_bytes },
        .{ "Media", if (media) size.media_bytes else 0 },
        .{ "Apps", size.apps_bytes },
        .{ "Plugins", size.plugins_bytes },
    };
    var shares: [parts.len]f64 = @splat(0);
    var total: u64 = 0;

    for (parts) |part| {
        total += part[1];
    }

    if (total == 0) {
        return &.{};
    }

    spread(&parts, &shares, total);

    var marks: std.ArrayList(Mark) = .empty;
    var at: f64 = 0;

    for (parts, shares) |part, share| {
        if (part[1] == 0) {
            continue;
        }

        try marks.append(arena, .{
            .label = part[0],
            .at = try std.fmt.allocPrint(arena, "{d:.2}%", .{at}),
            .span = try std.fmt.allocPrint(arena, "{d:.2}%", .{share}),
            .start = at,
            .width = share,
            .bytes = @floatFromInt(part[1]),
        });
        at += share;
    }

    std.debug.assert(marks.items.len <= parts.len);

    return marks.items;
}

const share_min_percent: f64 = 12;

/// Each part's share of the bar, out of 100: at least `share_min_percent`, the rest by weight.
fn spread(parts: anytype, shares: []f64, total: u64) void {
    std.debug.assert(total > 0);
    std.debug.assert(shares.len == parts.len);

    var small_count: f64 = 0;
    var large_bytes: f64 = 0;

    for (parts) |part| {
        const weight = @as(f64, @floatFromInt(part[1])) * 100 / @as(f64, @floatFromInt(total));

        if (part[1] > 0 and weight < share_min_percent) {
            small_count += 1;
        } else {
            large_bytes += @floatFromInt(part[1]);
        }
    }

    const left = 100 - small_count * share_min_percent;

    for (parts, shares) |part, *share| {
        const bytes: f64 = @floatFromInt(part[1]);
        const weight = bytes * 100 / @as(f64, @floatFromInt(total));

        share.* = if (part[1] == 0)
            0
        else if (weight < share_min_percent or large_bytes == 0)
            share_min_percent
        else
            bytes * left / large_bytes;
    }
}

fn since_began_ms(shared: *const Shared) i64 {
    std.debug.assert(shared.began_ms >= 0);

    return clock.wall_clock_ms(shared.io) - shared.began_ms;
}
