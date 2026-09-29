const std = @import("std");
const server = @import("../server.zig");
const report = @import("../lib/report.zig");
const routes = @import("routes.zig");
const http = @import("../lib/http.zig");
const apps_adapter = @import("../adapters/apps.zig");
const sdk = @import("../sdk.zig");
const build_command = @import("build.zig");

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
    /// With `--static`: build everything again, whatever the marker and the queue say.
    full: bool = false,
    exit: ?u8 = null,
};

pub fn run(init: std.process.Init, db_path: [:0]const u8, args: []const []const u8) !u8 {
    std.debug.assert(db_path.len > 0);
    std.debug.assert(port_default > 0);

    var flags = parse_flags(args);

    if (flags.exit) |code| {
        return code;
    }

    const port = flags.port;
    const browser_dir = flags.browser_dir;

    var application: server.Server = undefined;
    try application.init(init, db_path);
    defer application.deinit();

    var project: routes.Project = .{
        .connection = &application.connection,
        .auth = &application.auth,
        .io = init.io,
        .static_dir = browser_dir,
        .sandboxed_plugins = application.sandboxed(),
    };
    const first_port = port orelse if (browser_dir != null) browser_port_default else port_default;
    const search_span: u16 = if (port == null) port_search_max else 0;
    var options = server_options(first_port, browser_dir != null);

    var listener = start_server(init.gpa, &options, search_span) catch |err| {
        return switch (err) {
            error.AddressInUse => usage_port_in_use(@max(first_port, 1), search_span),
            else => err,
        };
    };
    defer listener.deinit();

    listener.user_data = &project;

    var reason: report.Reason = .{};
    var apps: []apps_adapter.App = &.{};
    defer if (apps.len > 0) init.gpa.free(apps);
    defer apps_adapter.load.close(&project);

    if (browser_dir != null) {
        routes.register_static(listener.router());
    } else {
        flags.apps.diagnostic = &reason;
        apps = try init.gpa.alloc(apps_adapter.App, apps_adapter.spec.all.len);
        start_apps(init.gpa, &application.index, &project, apps, flags);
        routes.register(listener.router());
    }

    announce(try listener.bound_port(), browser_dir);
    try listener.enable_shutdown_signals();

    try run_loop(&listener, &project);

    return 0;
}

/// An app that does not load affects the apps, never the CMS or its repair tools.
fn start_apps(
    gpa: std.mem.Allocator,
    index: *@import("../lib/deps.zig").Index,
    project: *routes.Project,
    apps: []apps_adapter.App,
    flags: Flags,
) void {
    std.debug.assert(project.apps.len == 0);
    std.debug.assert(apps.len == apps_adapter.spec.all.len);

    if (apps.len == 0) {
        return;
    }

    open_apps(gpa, index, project, apps, flags) catch |err| {
        project.apps_failed = true;
        const cause = if (flags.apps.diagnostic) |reason| reason.text() else "";
        report.warn_reason(
            cause,
            "publr serve: the apps are unavailable: {s}; the admin stays up at /admin",
            .{@errorName(err)},
        );
    };
}

fn run_loop(listener: *http.App, project: *routes.Project) !void {
    std.debug.assert(tick_ms > 0);
    // The loop is the server's, interleaved with the apps' rebuild queue: a batch that
    // went quiet (an admin's publish, a CLI's) is rebuilt between requests, never inside
    // one.
    while (listener.engine.phase != .stopped) {
        try listener.engine.tick(tick_ms);

        if (project.apps.len > 0) {
            tick_apps(project);
        }
    }
}

/// Every app loaded and validated, then: `--static` brings each app's build up to date now
/// (or builds it whole under `--full`), `--dev` serves nothing from a build, and otherwise
/// an existing build under `--out` is what is served.
fn open_apps(
    gpa: std.mem.Allocator,
    index: *@import("../lib/deps.zig").Index,
    project: *routes.Project,
    apps: []apps_adapter.App,
    flags: Flags,
) !void {
    std.debug.assert(project.apps.len == 0);
    std.debug.assert(flags.browser_dir == null);

    const now_ms = sdk.context.wall_clock_ms(project.io);

    try apps_adapter.load.open(project, apps, gpa, index, flags.apps, now_ms);

    if (flags.static) {
        const refreshed = try build_command.bring_up_to_date(project, flags.full);

        build_command.announce(refreshed, flags.apps.output_dir);
    } else if (flags.apps.dev) {
        std.debug.print("publr: --dev: rendering every page live, nothing cached\n", .{});
    } else {
        var served: u32 = 0;

        for (project.apps) |*app| {
            app.open_existing_output();

            if (app.output != null) {
                served += 1;
            }
        }

        if (served == 0) {
            std.debug.print("publr: no ./{s}/, rendering the apps on request; " ++
                "`publr build` makes them static\n", .{flags.apps.output_dir});
        }
    }
}

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
        build_command.announce(.{ .outcome = .built, .full = summary }, app.options.output_dir);
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
        return .{
            .address = loopback,
            .port = first_port,
            .connections_max = 8,
            .request_bytes_max = 64 << 10,
            .response_bytes_max = 4 << 20,
        };
    }

    return .{
        .address = loopback,
        .port = first_port,
        .connections_max = 64,
        .request_bytes_max = 64 << 10,
        .response_bytes_max = 2 << 20,
    };
}

const help =
    \\Usage: publr [--db <path>] serve [--port <n>] [--static [--full]] [--dev] [--out <dir>]
    \\                                  [--url <base>] [--apps <dir>]
    \\       publr [--db <path>] serve --browser [<dir>]
    \\
    \\  --port <n>        Listen on this exact port (default: 8080, or 8081 with --browser;
    \\                    without --port the next free port up to +20 is used)
    \\  --static          Bring every app's build up to date at startup, then serve the files:
    \\                    nothing when no change waits, the changed pages when some do
    \\  --full            With --static: build every page again
    \\  --dev             Render every page live, cache nothing, tint the islands
    \\  --out <dir>       The built apps to serve from, one folder each (default: output)
    \\  --url <base>      The project's public address: the apps' sitemaps, and the domain
    \\                    their subdomains hang from (default: http://127.0.0.1:8080)
    \\  --apps <dir>      Where each app's public files are read from, <dir>/<app>/public
    \\                    (default: apps)
    \\  --edge-max-age <s>
    \\                    How long a CDN in front may keep built pages and static islands
    \\                    (CDN-Cache-Control); for a CDN purged on every change (default 0)
    \\  --browser [<dir>] Serve the in-browser build statically (default zig-out/browser)
    \\  -h, --help        Print this help
    \\
;

fn parse_flags(args: []const []const u8) Flags {
    if (args.len >= 64) {
        return .{ .exit = usage("too many arguments") };
    }

    var flags: Flags = .{};
    var index: u32 = 0;

    while (index < args.len) : (index += 1) {
        const arg = args[index];

        if (std.mem.eql(u8, arg, "--port")) {
            index += 1;
            if (index == args.len) {
                return .{ .exit = usage("--port needs a value") };
            }
            flags.port = std.fmt.parseInt(u16, args[index], 10) catch
                return .{ .exit = usage("--port must be a number (0 picks a free port)") };
        } else if (std.mem.eql(u8, arg, "--static")) {
            flags.static = true;
        } else if (std.mem.eql(u8, arg, "--full")) {
            flags.full = true;
        } else if (std.mem.eql(u8, arg, "--dev")) {
            flags.apps.dev = true;
        } else if (text_option(&flags, arg)) |option| {
            index += 1;
            if (index == args.len) {
                return .{ .exit = usage("--out, --url and --apps need a value") };
            }
            option.* = args[index];
        } else if (std.mem.eql(u8, arg, "--edge-max-age")) {
            index += 1;
            const text = if (index < args.len) args[index] else "";
            flags.apps.edge_max_age = std.fmt.parseInt(u32, text, 10) catch
                return .{ .exit = usage("--edge-max-age needs a number of seconds") };
        } else if (std.mem.eql(u8, arg, "--browser")) {
            flags.browser_dir = browser_dir_default;
            if (index + 1 < args.len and !std.mem.startsWith(u8, args[index + 1], "--")) {
                index += 1;
                flags.browser_dir = args[index];
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("{s}", .{help});
            return .{ .exit = 0 };
        } else {
            report.err("publr serve: unknown flag \"{s}\"", .{arg});
            std.debug.print("{s}", .{help});
            return .{ .exit = 2 };
        }
    }

    flags.apps.base_url = std.mem.trimEnd(u8, flags.apps.base_url, "/");

    if (!apps_adapter.valid_options(flags.apps)) {
        return .{ .exit = usage("--out and --apps need a directory, --url an absolute HTTP(S) " ++
            "address") };
    }

    if (flags.browser_dir) |dir| {
        if (dir.len == 0) return .{ .exit = usage("--browser needs a nonempty directory") };
    }

    std.debug.assert(index == args.len);

    return flags;
}

/// Where a flag that takes text puts it; null for any other flag.
fn text_option(flags: *Flags, arg: []const u8) ?*[]const u8 {
    std.debug.assert(arg.len > 0);
    std.debug.assert(flags.exit == null);

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
    options: *http.Options,
    search_span: u16,
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

fn usage(message: []const u8) u8 {
    std.debug.assert(message.len > 0);
    std.debug.assert(message.len < 200);

    report.err("publr serve: {s}", .{message});
    std.debug.print("{s}", .{help});

    return 2;
}

test "a failed static build keeps the apps for recovery and releases them on shutdown" {
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
    try scratch.dir.writeFile(std.testing.io, .{ .sub_path = "file", .data = "occupied" });
    const path = try scratch.dir.realPathFileAlloc(std.testing.io, "file", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var apps: [apps_adapter.spec.all.len]apps_adapter.App = undefined;
    try open_apps(std.testing.allocator, &index, &project, &apps, .{
        .static = true,
        .apps = .{ .output_dir = path, .apps_dir = "fixtures/apps" },
    });
    defer apps_adapter.load.close(&project);
    try std.testing.expectEqual(@as(usize, apps.len), project.apps.len);

    for (project.apps) |*app| {
        try std.testing.expect(app.build_ready == (app.program == null));
    }
}

test "serve flags validate counts and paths before startup" {
    const many = [_][]const u8{"--static"} ** 64;
    try std.testing.expectEqual(@as(?u8, 2), parse_flags(&many).exit);
    try std.testing.expectEqual(@as(?u8, 2), parse_flags(&.{ "--out", "" }).exit);
    try std.testing.expectEqual(@as(?u8, 2), parse_flags(&.{ "--url", "///" }).exit);
    try std.testing.expectEqual(@as(?u8, 2), parse_flags(&.{ "--browser", "" }).exit);
}

test "an app whose build fails answers 503 until a publish lets it build" {
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
    _ = try registry.SDK.dispatch(&system, types.Create, .{ .definition = homepage });
    var index = try deps.Index.open(system.db, .{ .quiet_ms = deps.quiet_ms });
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    const path = try scratch.dir.realPathFileAlloc(std.testing.io, ".", system.arena);
    const www = apps_adapter.spec.find("www").?;
    var app: apps_adapter.App = undefined;
    try app.init(www, std.testing.allocator, std.testing.io, &index, .{
        .output_dir = path,
        .apps_dir = "fixtures/apps",
    }, 0);
    defer app.deinit();
    var diagnostic: engine.Diagnostic = .{ .arena = system.arena };
    const program = try engine.load(std.testing.allocator, &.{.{
        .rel = "content/index.publr",
        .source = "---\nconst home = Publr.build.getEntry({ type: 'homepage' });\n" ++
            "const hero = home.data.hero ?? '';\n---\n<h1>{hero}</h1>",
    }}, app.pages().options, &diagnostic);
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
    _ = try registry.SDK.dispatch(&system, records.Create, .{
        .type = "homepage",
        .document = "{\"hero\":\"Recovered homepage\"}",
        .status = "published",
    });
    retry_build(&app, &project, system.now_ms + deps.quiet_ms);
    try std.testing.expect(app.build_ready);
    const online = try flow.call("GET / HTTP/1.1\r\nHost: h\r\n\r\n", "");
    try std.testing.expectEqual(.ok, online.status);
    var buffer: [1024]u8 = undefined;
    const html = try scratch.dir.readFile(std.testing.io, "www/index.html", &buffer);
    try std.testing.expectEqualStrings("<h1>Recovered homepage</h1>", html);
}
