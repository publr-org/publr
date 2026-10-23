const std = @import("std");
const queue_worker = @import("queue_worker.zig");
const limits = @import("../model/limits.zig");
const plugin_hooks = @import("plugin_hooks.zig");
const server = @import("../server.zig");
const report = @import("../lib/report.zig");
const toolchain = @import("toolchain.zig");
const operator = @import("operator.zig");
const routes = @import("routes.zig");
const http = @import("../lib/http.zig");
const apps_adapter = @import("../adapters/apps.zig");
const model_app = @import("../model/app.zig");
const sdk = @import("../sdk.zig");
const build_command = @import("build.zig");
const apps_host = @import("apps_host.zig");
const plugin_build = @import("plugin_build.zig");
const live = @import("live.zig");
const agent_start = @import("agent_start.zig");
const update = @import("update.zig");

const port_default: u16 = 8080;
const browser_port_default: u16 = 8081;
const port_search_max: u16 = 20;
const browser_dir_default = "zig-out/browser";
const loopback: [4]u8 = .{ 127, 0, 0, 1 };
/// How long one event-loop wait may last before the rebuild queue is looked at.
const tick_ms: i32 = 250;

const Flags = struct {
    port: ?u16 = null,
    browser_dir: ?[]const u8 = null,
    apps: apps_adapter.Options = .{},
    /// Bring every app's build up to date at startup and serve it.
    static: bool = false,
    /// Stop after this long without a request; 0 never.
    idle_stop_s: u32 = 0,
    /// With `--static`: build everything again, whatever the marker and the queue say.
    full: bool = false,
    /// `--url` was given; without it the apps' address is this server's own.
    url_given: bool = false,
    /// `--admin-url`: the admin's own origin, away from the site's; empty: `/admin` beside it.
    admin_url: []const u8 = "",
    /// Why the flags were refused, printed with the help by `run`; parsing prints nothing.
    refused: []const u8 = "",
    /// A flag `serve` does not know.
    unknown: []const u8 = "",
    /// `--auto-update patch`: apply the newest patch of this minor once a day.
    auto_update: bool = false,
    help: bool = false,
};

pub fn run(init: std.process.Init, db_path: [:0]const u8, args: []const []const u8) !u8 {
    std.debug.assert(db_path.len > 0);

    const flags = parse_flags(args);

    if (exit_of(flags)) |code| {
        return code;
    }

    // Everything the run holds is let go before this process becomes the new binary.
    switch (try serve_project(init, db_path, flags)) {
        .stopped => return 0,
        .refused => return 1,
        .restart => {
            update.restart(init, db_path);
            return 1;
        },
    }
}

const Ended = enum { stopped, refused, restart };

/// After an update's swap, a release that cannot open the site gives way to the one it
/// replaced, which runs instead.
fn open_application(
    application: *server.Server,
    init: std.process.Init,
    db_path: [:0]const u8,
) !void {
    std.debug.assert(db_path.len > 0);

    application.init(init, db_path) catch |err| {
        update.go_back(init, db_path, err);
        return err;
    };

    std.debug.assert(application.runtime.open_count == 1);
}

/// Serves until stopped; `restart` when an update asked for it.
fn serve_project(init: std.process.Init, db_path: [:0]const u8, flags: Flags) !Ended {
    std.debug.assert(db_path.len > 0);

    const browser_dir = flags.browser_dir;

    // The browser build's server only hands out files: it owns no project.
    if (browser_dir == null and try another_server(init, db_path)) {
        return .refused;
    }

    var application: server.Server = undefined;
    try open_application(&application, init, db_path);
    defer application.deinit();

    const base = if (flags.url_given) model_app.path_of(flags.apps.base_url) else "";
    var project = project_of(init.io, &application, browser_dir, base);

    try name_cookies(init.arena.allocator(), &project);
    const first_port = flags.port orelse default_port(browser_dir != null);
    const search_span: u16 = if (flags.port == null) port_search_max else 0;
    var options = server_options(first_port, browser_dir != null);

    var listener = start_server(init.gpa, search_span, &options) catch |err| {
        if (err == error.AddressInUse) {
            _ = usage_port_in_use(@max(first_port, 1), search_span);
            return .refused;
        }

        return err;
    };
    defer listener.deinit();

    attach(&listener, &project);

    const bound = try listener.bound_port();

    var apps: apps_host.AppsHost = .{
        .gpa = init.gpa,
        .index = &application.index,
        .project = &project,
        .mode = try apps_mode(init.arena.allocator(), flags, bound),
    };
    defer apps.close();

    if (browser_dir != null) {
        routes.register_static(listener.router());
    } else {
        try split_hosts(
            &project,
            init.arena.allocator(),
            flags.admin_url,
            apps.mode.options.base_url,
        );
        apps.start();
        project.apps_host = &apps;
        routes.register(listener.router());
    }

    const session = try claim(init, db_path, bound, &apps, browser_dir == null);
    defer if (session != null) operator.close(init.io, init.arena.allocator(), db_path);

    var helpers = helpers_of(init, db_path, flags.auto_update);
    project.operator_key = if (session) |*owned| &owned.key else null;
    try helpers.attach(init, &project, session != null);
    announce(bound, browser_dir);

    if (browser_dir == null) {
        try started(init, &project, bound);
        update.served(init.io, init.arena.allocator(), db_path, @import("../publr.zig").version);
    }

    var keeper = try keeper_of(init, db_path, &project);
    defer keeper.stop();

    const worker: ?*queue_worker.Keeper = if (browser_dir == null) &keeper else null;

    try listener.enable_shutdown_signals();
    try run_loop(&listener, &project, worker, @as(i64, flags.idle_stop_s) * std.time.ms_per_s);

    return if (project.restart_requested) .restart else .stopped;
}

/// Queued work runs in a process of its own, so a slow hook or job never delays a request.
fn keeper_of(
    init: std.process.Init,
    db_path: [:0]const u8,
    project: *const routes.Project,
) !queue_worker.Keeper {
    std.debug.assert(db_path.len > 0);

    const arena = init.arena.allocator();
    // The site's and the admin's addresses: where its plugins' outside calls may go.
    const argv = try arena.dupe([]const u8, &.{
        try std.process.executablePathAlloc(init.io, arena),
        "--db",
        db_path,
        "queue-run",
        "--site-url",
        project.site_origin,
        "--admin-url",
        project.admin_origin,
    });

    std.debug.assert(argv.len == 8);

    return .{
        .io = init.io,
        .argv = argv,
    };
}

fn helpers_of(init: std.process.Init, db_path: [:0]const u8, auto_update: bool) Helpers {
    std.debug.assert(db_path.len > 0);

    return .{
        .builder = .{
            .io = init.io,
            .db_path = db_path,
        },
        .updater = .{
            .io = init.io,
            .db_path = db_path,
            .managed = is_managed(init),
            .auto = auto_update,
        },
    };
}

/// Publr Cloud runs this site and keeps its Publr up to date: `PUBLR_UPDATES=managed`.
fn is_managed(init: std.process.Init) bool {
    const value = init.environ_map.get("PUBLR_UPDATES") orelse "";

    std.debug.assert(value.len <= std.math.maxInt(u32));

    return std.mem.eql(u8, value, "managed");
}

/// The listener answering for `project`, under the path it is served at. The CLI beside the
/// server, and the servers of the project's other copies, call it on its own port at
/// `/_publr/...`, never under that path.
fn attach(listener: *http.App, project: *routes.Project) void {
    std.debug.assert(project.base.len == 0 or project.base[0] == '/');

    listener.user_data = project;
    listener.path_base = project.base;
    listener.path_base_exempt = "/_publr/";

    std.debug.assert(listener.user_data != null);
}

/// The project served: where it is on disk learned, the plugins told where it listens.
fn started(init: std.process.Init, project: *routes.Project, port: u16) !void {
    std.debug.assert(port > 0);
    std.debug.assert(project.static_dir == null);

    const arena = init.arena.allocator();

    try locate(init, project);
    try carry_on_interrupted(init, project);

    try plugin_hooks.serving(.{
        .io = init.io,
        .arena = arena,
        .project = project,
        .port = port,
    });
}

fn project_of(
    io: std.Io,
    application: *server.Server,
    browser_dir: ?[]const u8,
    base: []const u8,
) routes.Project {
    std.debug.assert(application.runtime.open_count == 1);
    std.debug.assert(browser_dir == null or browser_dir.?.len > 0);

    return .{
        .connection = &application.connection,
        .auth = &application.auth,
        .io = io,
        .static_dir = browser_dir,
        .base = base,
        .sandboxed_plugins = application.sandboxed(),
        .plugin_states = &application.plugin_states,
        .files = application.files_of(),
        .scratch = &application.scratch,
        .definitions = &application.definitions,
        .languages = &application.languages,
        .limits = &application.limits,
    };
}

/// The project's own cookie names, marked by when it was set up: two projects on one host
/// keep their sign-ins apart (`identity.cookie_names`). Not set up yet: the plain names.
fn name_cookies(arena: std.mem.Allocator, project: *routes.Project) !void {
    std.debug.assert(project.session_cookie.len > 0);

    const setup_key = @import("../operations/project.zig").setup_key;
    const settings = @import("../store/settings.zig");
    const set_up = try settings.get(project.connection, arena, setup_key) orelse return;
    const names = try @import("../adapters/rest/identity.zig").cookie_names(arena, set_up);

    project.session_cookie = names.session;
    project.hint_cookie = names.hint;
    project.visitor_cookie = names.visitor;
    project.member_cookie = names.member;

    std.debug.assert(!std.mem.eql(u8, names.session, names.hint));
}

/// The admin answers on an origin of its own, never the site's: `--admin-url`, else
/// `admin.<the site's host>` on the site's port (`admin.localhost` for a site on this
/// machine), and the site's host no longer serves it.
fn split_hosts(
    project: *routes.Project,
    arena: std.mem.Allocator,
    given_admin_url: []const u8,
    site_url: []const u8,
) !void {
    std.debug.assert(project.admin_origin.len == 0);
    std.debug.assert(site_url.len > 0);

    const admin_url = if (given_admin_url.len > 0)
        given_admin_url
    else
        default_admin_url(arena, site_url) catch {
            std.debug.print("publr serve: the site is at {s}, an address with no name to put " ++
                "the admin beside; name the admin's address with --admin-url\n", .{site_url});
            return error.NoAdminAddress;
        };
    const site_host = model_app.host_of(site_url);

    if (std.ascii.eqlIgnoreCase(site_host, model_app.host_of(admin_url))) {
        std.debug.print("publr serve: --admin-url names the site's own host ({s}); the " ++
            "admin needs another\n", .{site_host});
        return error.AdminOnSiteHost;
    }

    project.admin_origin = model_app.origin_of(admin_url);
    project.admin_base = model_app.path_of(admin_url);
    project.site_origin = model_app.origin_of(site_url);
    project.outside = try @import("project.zig").outside_of(
        arena,
        project.site_origin,
        project.admin_origin,
    );

    std.debug.assert(project.split());
}

/// `admin.<host>` on the site's scheme and port; `admin.localhost` for a site on this machine
/// (`127.0.0.1`, `localhost`, `*.localhost`). A site on another bare address has no name for
/// one.
fn default_admin_url(arena: std.mem.Allocator, site_url: []const u8) ![]const u8 {
    std.debug.assert(site_url.len > 0);

    const origin = model_app.origin_of(site_url);
    const scheme_end = std.mem.indexOf(u8, origin, "://") orelse return error.NoAdminAddress;
    const authority = origin[scheme_end + 3 ..];
    const port_at = std.mem.lastIndexOfScalar(u8, authority, ':');
    const host = if (port_at) |at| authority[0..at] else authority;
    const port = if (port_at) |at| authority[at..] else "";
    const local = std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "localhost") or
        std.mem.endsWith(u8, host, ".localhost");
    const dotted = std.mem.indexOfScalar(u8, host, '.') != null;
    const named = dotted and host.len > 0 and !std.ascii.isDigit(host[host.len - 1]);
    const scheme = origin[0 .. scheme_end + 3];

    if (local) {
        return std.fmt.allocPrint(arena, "{s}admin.localhost{s}", .{ scheme, port });
    }

    if (!named) {
        return error.NoAdminAddress;
    }

    return std.fmt.allocPrint(arena, "{s}admin.{s}{s}", .{ scheme, host, port });
}

/// Conversations whose turn was running when the last server stopped: their agent went with
/// it, so each ends as failed, saying so. Their devices are revoked as the server starts.
/// The turns the last server left working carry on: each agent starts again from the steps
/// already done, never leaving the work half made. Without agents here, they end.
fn carry_on_interrupted(init: std.process.Init, project: *routes.Project) !void {
    std.debug.assert(project.connection.transaction_depth == 0);
    std.debug.assert(project.static_dir == null);

    const store = @import("../store.zig");
    const now_ms = sdk.context.wall_clock_ms(init.io);
    const arena = init.arena.allocator();

    for (try store.ai_conversations.unfinished_devices(project.connection, arena)) |device_id| {
        _ = try store.devices.revoke(project.connection, device_id, now_ms);
    }

    const agents = project.agents orelse return end_interrupted(init, project);
    const working = try store.ai_conversations.left_working(project.connection, arena, now_ms);

    for (working) |id| {
        try store.ai_conversations.release_device(project.connection, id);
        _ = try store.ai_steps.append(project.connection, id, .{
            .kind = .said,
            .summary = carried_on,
            .detail = carried_on,
        }, now_ms);

        if (agents.start(agents.context, id)) |problem| {
            std.log.err("conversation {s} could not carry on: {s}", .{ id, problem });
        }
    }

    if (working.len > 0) {
        std.log.info("carrying on {d} conversation(s) the last server left working", .{
            working.len,
        });
    }
}

const carried_on = "The server restarted; carrying on where the work left off.";

fn end_interrupted(init: std.process.Init, project: *routes.Project) !void {
    std.debug.assert(project.connection.transaction_depth == 0);
    std.debug.assert(project.static_dir == null);

    const store = @import("../store.zig");
    const now_ms = sdk.context.wall_clock_ms(init.io);

    const ended = try store.ai_conversations.interrupt_all(
        project.connection,
        "The server stopped while this was being worked on. Ask again to carry on.",
        now_ms,
    );

    if (ended > 0) {
        std.log.info("ended {d} conversation(s) the last server left running", .{ended});
    }
}

/// Where the project is on disk, for the admin to tell an agent: the folder `serve` runs in
/// and its own binary, from there when it lies inside.
fn locate(init: std.process.Init, project: *routes.Project) !void {
    std.debug.assert(project.static_dir == null);
    std.debug.assert(project.folder.len == 0);

    const arena = init.arena.allocator();
    const folder = try std.Io.Dir.cwd().realPathFileAlloc(init.io, ".", arena);
    const executable = try std.process.executablePathAlloc(init.io, arena);

    project.folder = folder;
    project.binary = try binary_from(arena, folder, executable);

    std.debug.assert(project.binary.len > 0);
}

/// How to run `executable` from `folder`: relative when it lies inside, else as it is.
fn binary_from(
    arena: std.mem.Allocator,
    folder: []const u8,
    executable: []const u8,
) ![]const u8 {
    std.debug.assert(std.fs.path.isAbsolute(folder));
    std.debug.assert(std.fs.path.isAbsolute(executable));

    const inside = executable.len > folder.len + 1 and
        std.mem.startsWith(u8, executable, folder) and
        executable[folder.len] == std.fs.path.sep;

    if (!inside) {
        return executable;
    }

    const relative = executable[folder.len + 1 ..];

    return std.fmt.allocPrint(arena, ".{c}{s}", .{ std.fs.path.sep, relative });
}

fn default_port(browser: bool) u16 {
    std.debug.assert(browser_port_default != port_default);

    return if (browser) browser_port_default else port_default;
}

/// How the apps are served, their address this server's own unless `--url` named one.
fn apps_mode(arena: std.mem.Allocator, flags: Flags, bound: u16) !apps_host.Mode {
    std.debug.assert(bound > 0);
    std.debug.assert(flags.refused.len == 0);

    var options = flags.apps;

    if (!flags.url_given) {
        options.base_url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{bound});
    }

    return .{
        .options = options,
        .static = flags.static,
        .full = flags.full,
    };
}

/// The processes `serve` starts beside itself, each reporting back through the operator
/// channel, so only beside a CLI session: plugin builds (with the compiler carried) and
/// conversations' turns.
const Helpers = struct {
    builder: plugin_build.Builder,
    starter: agent_start.Starter = undefined,
    hub: live.Hub = .{},
    updater: update.Updater,

    fn attach(
        helpers: *Helpers,
        init: std.process.Init,
        project: *routes.Project,
        session: bool,
    ) !void {
        std.debug.assert(helpers.builder.db_path.len > 0);
        std.debug.assert(project.builder == null and project.agents == null);

        if (!session) {
            return;
        }

        const arena = init.arena.allocator();

        helpers.starter = .{
            .io = init.io,
            .db_path = helpers.builder.db_path,
        };
        project.agents = try helpers.starter.hook(arena);
        project.live = helpers.hub.live();
        project.updater = try helpers.updater.hook(arena);
        project.auto_update = if (helpers.updater.auto) &helpers.updater else null;

        if (toolchain.carried) {
            project.builder = try helpers.builder.hook(arena);
        }
    }
};

/// Whether a server already runs for this database, said when it does: one project, one
/// owner. When none does, the compiler for plugins is made ready before serving.
fn another_server(init: std.process.Init, db_path: [:0]const u8) !bool {
    std.debug.assert(db_path.len > 0);

    const running = try operator.find(init.io, init.arena.allocator(), db_path) orelse {
        toolchain.prepare(init);
        return false;
    };

    std.debug.assert(running.port > 0);
    report.err("publr serve: a server already runs for {s} on port {d}", .{
        db_path,
        running.port,
    });

    return true;
}

/// This server's session beside the database, which the CLI sends its commands through;
/// none for the browser build's server, which owns no project.
fn claim(
    init: std.process.Init,
    db_path: [:0]const u8,
    port: u16,
    apps: *const apps_host.AppsHost,
    owns_project: bool,
) !?operator.Session {
    std.debug.assert(port > 0);
    std.debug.assert(db_path.len > 0);

    if (!owns_project) {
        return null;
    }

    const url = apps.mode.options.base_url;

    return try operator.open(init.io, init.arena.allocator(), db_path, port, url);
}

fn run_loop(
    listener: *http.App,
    project: *routes.Project,
    worker: ?*queue_worker.Keeper,
    idle_stop_ms: i64,
) !void {
    std.debug.assert(tick_ms > 0);
    std.debug.assert(idle_stop_ms >= 0);

    var idle: Idle = .{
        .stop_ms = idle_stop_ms,
        .last_ms = sdk.context.wall_clock_ms(project.io),
    };

    // The loop is the server's, interleaved with the apps' rebuild queue: a batch that
    // went quiet (an admin's publish, a CLI's) is rebuilt between requests, never inside
    // one.
    while (listener.engine.phase != .stopped) {
        try listener.engine.tick(tick_ms);

        const counters = listener.engine.counters;
        const idle_over = idle.over(counters.requests_total, counters.active, project.io);

        if ((project.stop_requested or idle_over) and listener.engine.phase == .running) {
            listener.engine.stop();
        }

        if (worker) |keeper| {
            keeper.tick(sdk.context.wall_clock_ms(project.io));
        }

        if (project.apps.len > 0) {
            tick_apps(project);
        }

        if (project.auto_update) |updater| {
            updater.tick(sdk.context.wall_clock_ms(project.io));
        }
    }
}

/// `--idle-stop`: when the server last answered, by its count of requests.
const Idle = struct {
    stop_ms: i64,
    last_ms: i64,
    seen: u64 = 0,

    /// Whether nothing has asked for as long as `stop_ms`, with no connection open.
    fn over(idle: *Idle, requests_total: u64, active: u32, io: std.Io) bool {
        std.debug.assert(idle.stop_ms >= 0);
        std.debug.assert(requests_total >= idle.seen);

        if (idle.stop_ms == 0) {
            return false;
        }

        const now_ms = sdk.context.wall_clock_ms(io);

        if (requests_total != idle.seen or active > 0) {
            idle.seen = requests_total;
            idle.last_ms = now_ms;
        }

        return now_ms - idle.last_ms >= idle.stop_ms;
    }
};

fn tick_apps(project: *const routes.Project) void {
    std.debug.assert(project.apps.len > 0);
    std.debug.assert(tick_ms > 0);

    const now_ms = sdk.context.wall_clock_ms(project.io);

    for (project.apps) |*app| {
        if (!app.build_ready) {
            retry_build(app, project, now_ms);
        }
    }

    if (apps_adapter.rebuild.due(project, now_ms)) {
        apps_adapter.rebuild.flush(project, now_ms);
    }
}

/// A failed build has no dependency graph to follow: build the app again after a write.
fn retry_build(app: *apps_adapter.App, project: *const routes.Project, now_ms: i64) void {
    std.debug.assert(!app.build_ready);
    std.debug.assert(now_ms >= 0);

    const revision = app.index.revision() catch return;

    if (revision == app.retry_revision) {
        return;
    }

    if (!(app.index.due(now_ms) catch false)) {
        return;
    }

    const summary = apps_adapter.build.build_or_fail(app, project);

    if (app.build_ready) {
        build_command.announce(.{
            .outcome = .built,
            .full = summary,
        }, app.options.output_dir);
    }
}

fn announce(bound: u16, browser_dir: ?[]const u8) void {
    std.debug.assert(bound > 0);
    std.debug.assert(loopback.len == 4);

    if (browser_dir) |dir| {
        std.debug.print("publr serving the browser build from {s} on http://127.0.0.1:{d}/\n", .{
            dir,
            bound,
        });
    } else {
        std.debug.print("publr listening on http://127.0.0.1:{d}\n", .{bound});
    }
}

/// The browser build is served to one tab; the native server takes the admin's traffic
/// and the apps', so it gets more slots and the response cap a whole page needs.
fn server_options(first_port: u16, browser: bool) http.Options {
    std.debug.assert(loopback[0] == 127);
    std.debug.assert(port_search_max > 0);

    if (browser) {
        // The whole browser build's module in one response: 8.4 MiB in ReleaseSmall on
        // 2026-10-06 once it resized images, 16.1 MiB on 2026-10-15, with room to grow.
        const response_bytes_max: u32 = 32 << 20;

        return .{
            .address = loopback,
            .port = first_port,
            .connections_max = 8,
            // A visual page's whole document posts in one autosave.
            .request_bytes_max = limits.request_bytes_max,
            // A file is read whole into the arena, in a buffer as large as a response.
            .arena_bytes = limits.request_arena_bytes + response_bytes_max,
            .response_bytes_max = response_bytes_max,
        };
    }

    return .{
        .address = loopback,
        .port = first_port,
        .connections_max = 64,
        .request_bytes_max = limits.request_bytes_max,
        .response_bytes_max = 2 << 20,
        .arena_bytes = limits.request_arena_bytes,
    };
}

const help =
    \\Usage: publr [--db <path>] serve [--port <n>] [--static [--full]] [--dev] [--out <dir>]
    \\                                  [--url <base>] [--admin-url <url>] [--apps <dir>]
    \\       publr [--db <path>] serve --browser [<dir>]
    \\
    \\  --port <n>        Listen on this exact port (default: 8080, or 8081 with --browser;
    \\                    without --port the next free port up to +20 is used)
    \\  --static          Bring every app's build up to date at startup, then serve the files:
    \\                    nothing when no change waits, the changed pages when some do
    \\  --full            With --static: build every page again
    \\  --dev             Render every page live, cache nothing, tint the islands
    \\  --out <dir>       The built apps to serve from, one folder each (default: output)
    \\  --admin-url <url> The admin's own address, another host or port than the site's
    \\                    (http://admin.localhost:8080): the site's host then sends /admin
    \\                    there, and a signed-in administrator sees the site as it is; a
    \\                    path under it when the host is shared, the proxy taking it off
    \\  --url <base>      The project's public address: the apps' sitemaps, and the domain
    \\                    their subdomains hang from (default: this server's own address);
    \\                    a path in it is where the whole project is served
    \\  --apps <dir>      Where each app's public files are read from, <dir>/<folder>/public
    \\                    (default: apps)
    \\  --idle-stop <s>   Stop after this many seconds without a request (default: never)
    \\  --auto-update patch
    \\                    Once a day, update to the newest patch of this release (backed up,
    \\                    rehearsed, restarted in place); minor and major releases are yours
    \\  --edge-max-age <s>
    \\                    How long a CDN in front may keep built pages and static islands
    \\                    (CDN-Cache-Control); for a CDN purged on every change (default 0)
    \\  --browser [<dir>] Serve the in-browser build statically (default zig-out/browser)
    \\  -h, --help        Print this help
    \\
;

/// The number of seconds after the flag at `index`, which moves past it; null when there is
/// none.
fn seconds_after(args: []const []const u8, index: *u32) ?u32 {
    std.debug.assert(index.* < args.len);

    index.* += 1;

    const text = if (index.* < args.len) args[index.*] else "";

    return std.fmt.parseInt(u32, text, 10) catch null;
}

const auto_update_refused = "--auto-update takes `patch`: minor and major releases are yours";

fn parse_flags(args: []const []const u8) Flags {
    if (args.len >= 64) {
        return .{
            .refused = "too many arguments",
        };
    }

    var flags: Flags = .{};
    var index: u32 = 0;

    while (index < args.len) : (index += 1) {
        const arg = args[index];

        if (std.mem.eql(u8, arg, "--port")) {
            index += 1;
            if (index == args.len) {
                return .{
                    .refused = "--port needs a value",
                };
            }
            flags.port = std.fmt.parseInt(u16, args[index], 10) catch
                return .{
                    .refused = "--port must be a number (0 picks a free port)",
                };
        } else if (std.mem.eql(u8, arg, "--idle-stop")) {
            flags.idle_stop_s = seconds_after(args, &index) orelse
                return .{
                    .refused = "--idle-stop needs a number of seconds",
                };
        } else if (std.mem.eql(u8, arg, "--auto-update")) {
            index += 1;
            flags.auto_update = index < args.len and std.mem.eql(u8, args[index], "patch");
            flags.refused = if (flags.auto_update) flags.refused else auto_update_refused;
        } else if (std.mem.eql(u8, arg, "--static")) {
            flags.static = true;
        } else if (std.mem.eql(u8, arg, "--full")) {
            flags.full = true;
        } else if (std.mem.eql(u8, arg, "--dev")) {
            flags.apps.dev = true;
        } else if (text_option(&flags, arg)) |option| {
            index += 1;
            if (index == args.len) {
                return .{
                    .refused = "--out, --url and --apps need a value",
                };
            }
            option.* = args[index];
            flags.url_given = flags.url_given or std.mem.eql(u8, arg, "--url");
        } else if (std.mem.eql(u8, arg, "--admin-url")) {
            index += 1;
            flags.admin_url = if (index < args.len) admin_origin(args[index]) else "";
            if (flags.admin_url.len == 0) {
                return .{
                    .refused = "--admin-url needs an address, a path under it at most: " ++
                        "http://admin.localhost:8080",
                };
            }
        } else if (std.mem.eql(u8, arg, "--edge-max-age")) {
            flags.apps.edge_max_age = seconds_after(args, &index) orelse
                return .{
                    .refused = "--edge-max-age needs a number of seconds",
                };
        } else if (std.mem.eql(u8, arg, "--browser")) {
            flags.browser_dir = browser_dir_default;
            if (index + 1 < args.len and !std.mem.startsWith(u8, args[index + 1], "--")) {
                index += 1;
                flags.browser_dir = args[index];
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return .{
                .help = true,
            };
        } else {
            return .{
                .unknown = arg,
            };
        }
    }

    flags.apps.base_url = std.mem.trimEnd(u8, flags.apps.base_url, "/");

    if (!apps_adapter.valid_options(flags.apps)) {
        return .{
            .refused = "--out and --apps need a directory, --url an absolute HTTP(S) " ++
                "address",
        };
    }

    if (flags.browser_dir) |dir| {
        if (dir.len == 0) {
            return .{
                .refused = "--browser needs a nonempty directory",
            };
        }
    }

    std.debug.assert(index == args.len);

    return flags;
}

/// An HTTP(S) address with a host and no path, as the admin's origin; empty otherwise.
/// The admin's address: an origin, and a path under it when the host is shared (Publr
/// Cloud's dashboard: `https://cloud.publr.app/spaces/ada/shop`). A path is lower-case
/// segments of a-z, 0-9, `-` and `_`; anything else is refused.
fn admin_origin(text: []const u8) []const u8 {
    std.debug.assert(text.len <= 64 << 10);

    const address = std.mem.trimEnd(u8, text, "/");
    const web = std.mem.startsWith(u8, address, "http://") or
        std.mem.startsWith(u8, address, "https://");

    const path_valid = admin_path_valid(model_app.path_of(address));

    if (!web or model_app.host_of(address).len == 0 or !path_valid) {
        return "";
    }

    return address;
}

fn admin_path_valid(path: []const u8) bool {
    std.debug.assert(path.len <= 64 << 10);

    if (path.len == 0) {
        return true;
    }

    if (path[0] != '/' or path[path.len - 1] == '/' or std.mem.indexOf(u8, path, "//") != null) {
        return false;
    }

    for (path) |char| {
        const allowed = (char >= 'a' and char <= 'z') or (char >= '0' and char <= '9') or
            char == '-' or char == '_' or char == '/';

        if (!allowed) {
            return false;
        }
    }

    return true;
}

/// Where a flag that takes text puts it; null for any other flag.
fn text_option(flags: *Flags, arg: []const u8) ?*[]const u8 {
    std.debug.assert(arg.len > 0);
    std.debug.assert(flags.refused.len == 0);

    if (std.mem.eql(u8, arg, "--out")) {
        return &flags.apps.output_dir;
    }

    if (std.mem.eql(u8, arg, "--url")) {
        return &flags.apps.base_url;
    }

    if (std.mem.eql(u8, arg, "--apps")) {
        return &flags.apps.apps_dir;
    }

    return null;
}

fn start_server(
    gpa: std.mem.Allocator,
    search_span: u16,
    options: *http.Options,
) http.App.Error!http.App {
    std.debug.assert(search_span <= port_search_max);
    std.debug.assert(options.port > 0 or search_span == 0);

    const first_port = options.port;
    var attempt: u16 = 0;

    while (attempt <= search_span) : (attempt += 1) {
        options.port = std.math.add(u16, first_port, attempt) catch {
            return error.AddressInUse;
        };

        return http.App.init(gpa, options.*) catch |err| {
            if (err == error.AddressInUse and attempt < search_span) {
                continue;
            }

            return err;
        };
    }

    unreachable;
}

fn usage_port_in_use(first_port: u16, search_span: u16) u8 {
    std.debug.assert(first_port > 0);
    std.debug.assert(search_span <= port_search_max);

    if (search_span == 0) {
        report.err("publr serve: port {d} is already in use; pick another with --port <n>", .{
            first_port,
        });
    } else {
        report.err("publr serve: ports {d}-{d} are all in use; free one or use --port <n>", .{
            first_port,
            first_port + search_span,
        });
    }

    return 1;
}

/// The help, or why the flags were refused, printed; null when `serve` should start.
fn exit_of(flags: Flags) ?u8 {
    std.debug.assert(flags.refused.len < 200);
    std.debug.assert(flags.unknown.len < 4096);

    if (flags.help) {
        std.debug.print("{s}", .{help});
        return 0;
    }

    if (flags.unknown.len > 0) {
        report.err("publr serve: unknown flag \"{s}\"", .{flags.unknown});
        std.debug.print("{s}", .{help});
        return 2;
    }

    if (flags.refused.len > 0) {
        return usage(flags.refused);
    }

    return null;
}

fn usage(message: []const u8) u8 {
    std.debug.assert(message.len > 0);
    std.debug.assert(message.len < 200);

    report.err("publr serve: {s}", .{message});
    std.debug.print("{s}", .{help});

    return 2;
}

test "a failed static build keeps the apps for recovery and releases them on shutdown" {
    // A failed build is what this checks: its warning is expected.
    std.testing.log_level = .err;

    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var index = try @import("../lib/deps.zig").Index.open(&harness.fixture.connection, .{});
    var project: routes.Project = .{
        .connection = &harness.fixture.connection,
        .auth = &harness.auth,
        .io = std.testing.io,
    };
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    try scratch.dir.writeFile(std.testing.io, .{
        .sub_path = "file",
        .data = "occupied",
    });
    const path = try scratch.dir.realPathFileAlloc(std.testing.io, "file", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var host: apps_host.AppsHost = .{
        .gpa = std.testing.allocator,
        .index = &index,
        .project = &project,
        .mode = .{
            .static = true,
            .options = .{
                .output_dir = path,
                .apps_dir = "fixtures/apps",
            },
        },
    };
    try host.reload();
    defer host.close();
    try std.testing.expectEqual(@as(usize, host.apps.len), project.apps.len);

    for (project.apps) |*app| {
        try std.testing.expect(app.build_ready == (app.program == null));
    }
}

test "the binary is named from the project's folder when it lies inside" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "./zig-out/bin/publr",
        try binary_from(arena, "/sites/blog", "/sites/blog/zig-out/bin/publr"),
    );
    try std.testing.expectEqualStrings(
        "/usr/local/bin/publr",
        try binary_from(arena, "/sites/blog", "/usr/local/bin/publr"),
    );
    try std.testing.expectEqualStrings(
        "/sites/blog-old/publr",
        try binary_from(arena, "/sites/blog", "/sites/blog-old/publr"),
    );
}

test "serve flags validate counts and paths before startup" {
    const many = [_][]const u8{"--static"} ** 64;
    try std.testing.expect(parse_flags(&many).refused.len > 0);
    try std.testing.expect(parse_flags(&.{ "--out", "" }).refused.len > 0);
    try std.testing.expect(parse_flags(&.{ "--url", "///" }).refused.len > 0);
    try std.testing.expectEqualStrings(
        "http://admin.localhost:8080",
        parse_flags(&.{ "--admin-url", "http://admin.localhost:8080/" }).admin_url,
    );
    const shared = "http://cloud.publr.localhost:8095/spaces/ada/shop";

    try std.testing.expectEqualStrings(
        shared,
        parse_flags(&.{ "--admin-url", shared ++ "/" }).admin_url,
    );
    try std.testing.expect(parse_flags(&.{ "--admin-url", "http://a.test/Admin" }).refused.len > 0);
    try std.testing.expect(parse_flags(&.{ "--admin-url", "http://a.test/a//b" }).refused.len > 0);
    try std.testing.expect(parse_flags(&.{ "--admin-url", "http://a.test/a?b" }).refused.len > 0);
    try std.testing.expect(parse_flags(&.{ "--admin-url", "admin.localhost" }).refused.len > 0);
    try std.testing.expect(parse_flags(&.{"--admin-url"}).refused.len > 0);
    try std.testing.expect(parse_flags(&.{ "--browser", "" }).refused.len > 0);
}

test "an app whose build fails answers 503 until a publish lets it build" {
    // A failed build is what this checks: its warning is expected.
    std.testing.log_level = .err;

    const engine = @import("../template.zig");
    const registry = @import("registry.zig");
    const records = @import("../operations/record.zig");
    const types = @import("../operations/content_type.zig");
    const deps = @import("../lib/deps.zig");
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var system = harness.ctx(.system);
    const homepage = "{\"handle\":\"homepage\",\"name\":\"Homepage\",\"kind\":\"settings\"," ++
        "\"public\":true,\"title_field\":\"\",\"fields\":[" ++
        "{\"name\":\"hero\",\"label\":\"Hero\",\"kind\":\"string\"}]}";
    _ = try registry.SDK.dispatch(&system, types.Create, .{
        .definition = homepage,
    });
    var index = try deps.Index.open(system.db, .{
        .quiet_ms = deps.quiet_ms,
    });
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    const path = try scratch.dir.realPathFileAlloc(std.testing.io, ".", system.arena);
    const www = apps_adapter.spec.find("www").?;
    var app: apps_adapter.App = undefined;
    try app.init(www, std.testing.allocator, std.testing.io, &index, 0, .{
        .output_dir = path,
        .apps_dir = "fixtures/apps",
    });
    defer app.deinit();
    var diagnostic: engine.Diagnostic = .{
        .arena = system.arena,
    };
    const program = try engine.load(std.testing.allocator, &.{.{
        .rel = "content/index.publr",
        .source = "---\nconst home = Publr.build.getEntry({ type: 'homepage' });\n" ++
            "const hero = home.data.hero ?? '';\n---\n<h1>{hero}</h1>",
    }}, &diagnostic, app.pages().options);
    defer std.testing.allocator.destroy(program);
    defer program.deinit();
    const original = app.program;
    app.program = program;
    defer app.program = original;
    const project: routes.Project = .{
        .connection = system.db,
        .auth = &harness.auth,
        .io = std.testing.io,
        .apps = (&app)[0..1],
    };
    const failed = apps_adapter.build.build_or_fail(&app, &project);
    try std.testing.expectEqual(@as(u32, 1), failed.failed);
    retry_build(&app, &project, system.now_ms + deps.quiet_ms);
    try std.testing.expect(!app.build_ready);
    var flow: routes.testing.Flow = undefined;
    flow.init(project, system.arena);
    const offline = try flow.call("GET / HTTP/1.1\r\nHost: h\r\n\r\n", "");
    try std.testing.expectEqual(.service_unavailable, offline.status);
    try std.testing.expectEqualStrings("no-store", offline.header("Cache-Control").?);
    const fragment = try flow.call("GET /_islands/test HTTP/1.1\r\nHost: h\r\n\r\n", "");
    try std.testing.expectEqual(.service_unavailable, fragment.status);
    const cms = try flow.call("GET /admin/settings HTTP/1.1\r\nHost: h\r\n\r\n", "");
    try std.testing.expect(cms.header("Location") != null);
    const health = try flow.call("GET /api/health HTTP/1.1\r\nHost: h\r\n\r\n", "");
    try std.testing.expectEqual(.ok, health.status);
    const recovered = try registry.SDK.dispatch(&system, records.Create, .{
        .type = "homepage",
        .document = "{\"hero\":\"Recovered homepage\"}",
    });
    _ = try registry.SDK.dispatch(&system, records.Publish, .{
        .id = recovered.id,
    });
    retry_build(&app, &project, system.now_ms + deps.quiet_ms);
    try std.testing.expect(app.build_ready);
    const online = try flow.call("GET / HTTP/1.1\r\nHost: h\r\n\r\n", "");
    try std.testing.expectEqual(.ok, online.status);
    var buffer: [1024]u8 = undefined;
    const html = try scratch.dir.readFile(std.testing.io, "www/index.html", &buffer);
    try std.testing.expectEqualStrings("<h1>Recovered homepage</h1>", html);
}

test "the admin is given an origin of its own: admin.<host>, admin.localhost on this machine" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "http://admin.localhost:8080",
        try default_admin_url(arena, "http://127.0.0.1:8080"),
    );
    try std.testing.expectEqualStrings(
        "http://admin.localhost:8080",
        try default_admin_url(arena, "http://shop.localhost:8080/"),
    );
    try std.testing.expectEqualStrings(
        "https://admin.example.com",
        try default_admin_url(arena, "https://example.com"),
    );
    try std.testing.expectError(
        error.NoAdminAddress,
        default_admin_url(arena, "http://10.0.0.5:8080"),
    );
}
