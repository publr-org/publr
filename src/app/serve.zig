const std = @import("std");
const app = @import("../app.zig");
const report = @import("../lib/report.zig");
const routes = @import("routes.zig");
const http = @import("../lib/http.zig");
const site_adapter = @import("../adapters/site.zig");
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
    site: site_adapter.Options = .{},
    /// Bring the built site up to date at startup and serve it.
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

    var application: app.App = undefined;
    try application.init(init, db_path);
    defer application.deinit();

    var site: routes.Site = .{
        .connection = &application.connection,
        .auth = &application.auth,
        .io = init.io,
        .static_dir = browser_dir,
    };
    const first_port = port orelse if (browser_dir != null) browser_port_default else port_default;
    const search_span: u16 = if (port == null) port_search_max else 0;
    var options = server_options(first_port, browser_dir != null);

    var server = start_server(init.gpa, &options, search_span) catch |err| {
        return switch (err) {
            error.AddressInUse => usage_port_in_use(@max(first_port, 1), search_span),
            else => err,
        };
    };
    defer server.deinit();

    server.user_data = &site;

    var reason: report.Reason = .{};
    var public: site_adapter.Public = undefined;
    var has_public = false;
    defer if (has_public) public.deinit();

    if (browser_dir != null) {
        routes.register_static(server.router());
    } else {
        flags.site.diagnostic = &reason;
        has_public = start_site(init.gpa, &application.index, &site, &public, flags);
        routes.register(server.router());
    }

    announce(try server.bound_port(), browser_dir);
    try server.enable_shutdown_signals();

    try run_loop(&server, if (has_public) &public else null, &site);

    return 0;
}

/// A theme failure affects public delivery, never the CMS or its repair tools.
fn start_site(
    gpa: std.mem.Allocator,
    index: *@import("../lib/deps.zig").Index,
    site: *routes.Site,
    public: *site_adapter.Public,
    flags: Flags,
) bool {
    std.debug.assert(site.public == null);
    open_site(gpa, index, site, public, flags) catch |err| {
        site.public_failed = true;
        const cause = if (flags.site.diagnostic) |reason| reason.text() else "";
        report.warn_reason(
            cause,
            "publr serve: public site unavailable: {s}; CMS remains available at /admin",
            .{@errorName(err)},
        );
        return false;
    };
    return true;
}

fn run_loop(server: *http.App, public: ?*site_adapter.Public, site: *routes.Site) !void {
    std.debug.assert(tick_ms > 0);
    // The loop is the server's, interleaved with the site's rebuild queue: a batch that
    // went quiet (an admin's publish, a CLI's) is rebuilt between requests, never inside
    // one.
    while (server.engine.phase != .stopped) {
        try server.engine.tick(tick_ms);

        if (public) |loaded| {
            flush_site(loaded, site);
        }
    }
}

/// The theme loaded and validated, then: `--static` brings the build up to date now (or
/// builds it whole under `--full`), `--dev` serves nothing from a build, and otherwise an
/// existing build under `--out` is what is served.
fn open_site(
    gpa: std.mem.Allocator,
    index: *@import("../lib/deps.zig").Index,
    site: *routes.Site,
    public: *site_adapter.Public,
    flags: Flags,
) !void {
    std.debug.assert(site.public == null);
    std.debug.assert(flags.browser_dir == null);

    const now_ms = sdk.context.wall_clock_ms(site.io);

    try public.init(gpa, site.io, index, flags.site, now_ms);
    errdefer public.deinit();

    site.public = public;
    errdefer site.public = null;

    if (flags.static) {
        const refreshed = build_command.bring_up_to_date(public, site, flags.full) catch |err| {
            build_failed(public, err);
            return;
        };

        build_command.announce(refreshed, flags.site.output_dir);
    } else if (flags.site.dev) {
        std.debug.print("publr: --dev: rendering every page live, nothing cached\n", .{});
    } else {
        public.open_existing_output();

        if (public.output == null) {
            std.debug.print("publr: no ./{s}/, rendering the site on request; " ++
                "`publr build` makes it static\n", .{flags.site.output_dir});
        }
    }
}

fn build_failed(public: *site_adapter.Public, err: anyerror) void {
    std.debug.assert(public.theme.routes.len > 0);
    public.build_ready = false;
    public.retry_revision = public.index.revision() catch 0;
    const cause = if (public.options.diagnostic) |reason| reason.text() else "";
    report.warn_reason(
        cause,
        "publr serve: public site build failed: {s}; CMS remains available at /admin",
        .{@errorName(err)},
    );
}

fn flush_site(public: *site_adapter.Public, site: *const routes.Site) void {
    std.debug.assert(site.public == public);
    std.debug.assert(tick_ms > 0);

    const now_ms = sdk.context.wall_clock_ms(site.io);

    if (!public.build_ready) {
        retry_build(public, site, now_ms);
        return;
    }

    if (site_adapter.rebuild.due(public, now_ms)) {
        site_adapter.rebuild.flush(public, site, now_ms);
    }
}

/// A failed first build has no dependency graph yet: retry the full build after a write.
fn retry_build(public: *site_adapter.Public, site: *const routes.Site, now_ms: i64) void {
    std.debug.assert(!public.build_ready);
    const revision = public.index.revision() catch return;

    if (revision == public.retry_revision) {
        return;
    }

    if (!(public.index.due(now_ms) catch false)) {
        return;
    }

    const summary = site_adapter.build.build(public, site) catch |err| {
        build_failed(public, err);
        return;
    };
    public.build_ready = true;
    build_command.announce(.{ .outcome = .built, .full = summary }, public.options.output_dir);
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
/// and the site's, so it gets more slots and the response cap a whole page needs.
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
    \\                                  [--url <base>]
    \\       publr [--db <path>] serve --browser [<dir>]
    \\
    \\  --port <n>        Listen on this exact port (default: 8080, or 8081 with --browser;
    \\                    without --port the next free port up to +20 is used)
    \\  --static          Bring the built site up to date at startup, then serve the files:
    \\                    nothing when no change waits, the changed pages when some do
    \\  --full            With --static: build every page again
    \\  --dev             Render every page live, cache nothing, tint the islands
    \\  --out <dir>       The built site to serve from, when present (default: output)
    \\  --url <base>      The site's public address, for the sitemap
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
            flags.site.dev = true;
        } else if (std.mem.eql(u8, arg, "--out")) {
            index += 1;
            if (index == args.len) {
                return .{ .exit = usage("--out needs a directory") };
            }
            flags.site.output_dir = args[index];
        } else if (std.mem.eql(u8, arg, "--url")) {
            index += 1;
            if (index == args.len) {
                return .{ .exit = usage("--url needs an address") };
            }
            flags.site.base_url = std.mem.trimEnd(u8, args[index], "/");
        } else if (std.mem.eql(u8, arg, "--edge-max-age")) {
            index += 1;
            const text = if (index < args.len) args[index] else "";
            flags.site.edge_max_age = std.fmt.parseInt(u32, text, 10) catch
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

    if (!site_adapter.valid_options(flags.site)) {
        return .{ .exit = usage("--out needs a directory and --url an absolute HTTP(S) address") };
    }

    if (flags.browser_dir) |dir| {
        if (dir.len == 0) return .{ .exit = usage("--browser needs a nonempty directory") };
    }

    std.debug.assert(index == args.len);

    return flags;
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

test "failed static build retains the theme for recovery and releases it on shutdown" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var index = try @import("../lib/deps.zig").Index.open(&harness.fixture.connection, .{});
    var site: routes.Site = .{
        .connection = &harness.fixture.connection,
        .auth = &harness.auth,
        .io = std.testing.io,
    };
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    try scratch.dir.writeFile(std.testing.io, .{ .sub_path = "file", .data = "occupied" });
    const path = try scratch.dir.realPathFileAlloc(std.testing.io, "file", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var public: site_adapter.Public = undefined;
    try open_site(
        std.testing.allocator,
        &index,
        &site,
        &public,
        .{
            .static = true,
            .site = .{ .output_dir = path },
        },
    );
    defer public.deinit();
    try std.testing.expect(site.public == &public);
    try std.testing.expect(!public.build_ready);
}

test "missing Caraway content keeps the CMS running with public delivery unavailable" {
    if (!std.mem.eql(u8, site_adapter.theme_name, "caraway")) {
        return error.SkipZigTest;
    }

    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var index = try @import("../lib/deps.zig").Index.open(&harness.fixture.connection, .{});
    var site: routes.Site = .{
        .connection = &harness.fixture.connection,
        .auth = &harness.auth,
        .io = std.testing.io,
    };
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    const path = try scratch.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var public: site_adapter.Public = undefined;
    try open_site(
        std.testing.allocator,
        &index,
        &site,
        &public,
        .{
            .static = true,
            .site = .{ .output_dir = path },
        },
    );
    defer public.deinit();
    try std.testing.expect(site.public == &public);
    try std.testing.expect(!public.build_ready);
}

test "serve flags validate counts and paths before startup" {
    const many = [_][]const u8{"--static"} ** 64;
    try std.testing.expectEqual(@as(?u8, 2), parse_flags(&many).exit);
    try std.testing.expectEqual(@as(?u8, 2), parse_flags(&.{ "--out", "" }).exit);
    try std.testing.expectEqual(@as(?u8, 2), parse_flags(&.{ "--url", "///" }).exit);
    try std.testing.expectEqual(@as(?u8, 2), parse_flags(&.{ "--browser", "" }).exit);
}

test "a failed initial homepage build recovers after publishing the website settings" {
    const engine = @import("../theme.zig");
    const registry = @import("registry.zig");
    const records = @import("../operations/record.zig");
    const settings = @import("../operations/settings.zig");
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var system = harness.ctx(.system);
    try settings.ensure(&system);
    const deps = @import("../lib/deps.zig");
    var index = try deps.Index.open(system.db, .{ .quiet_ms = deps.quiet_ms });
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    const path = try scratch.dir.realPathFileAlloc(std.testing.io, ".", system.arena);
    var public: site_adapter.Public = undefined;
    try public.init(std.testing.allocator, std.testing.io, &index, .{ .output_dir = path }, 0);
    defer public.deinit();
    var diagnostic: engine.Diagnostic = .{ .arena = system.arena };
    const theme = try engine.load(std.testing.allocator, &.{.{
        .rel = "content/index.publr",
        .source = "---\nconst home = Publr.context.entry;\n" ++
            "const title = home.data.hero_title ?? '';\n---\n<h1>{title}</h1>",
    }}, public.theme.options, &diagnostic);
    defer std.testing.allocator.destroy(theme);
    defer theme.deinit();
    const original = public.theme;
    public.theme = theme;
    defer public.theme = original;
    const site: routes.Site = .{
        .connection = system.db,
        .auth = &harness.auth,
        .io = std.testing.io,
        .public = &public,
    };
    const result = site_adapter.build.build(&public, &site);
    try std.testing.expectError(error.HomepageNotSet, result);
    build_failed(&public, error.HomepageNotSet);
    retry_build(&public, &site, system.now_ms + deps.quiet_ms);
    try std.testing.expect(!public.build_ready);
    var flow: routes.testing.Flow = undefined;
    flow.init(site, system.arena);
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
        .type = settings.handle,
        .document = "{\"hero_title\":\"Recovered homepage\"}",
        .status = "published",
    });
    retry_build(&public, &site, system.now_ms + deps.quiet_ms);
    try std.testing.expect(public.build_ready);
    const online = try flow.call("GET / HTTP/1.1\r\nHost: h\r\n\r\n", "");
    try std.testing.expectEqual(.ok, online.status);
    var buffer: [1024]u8 = undefined;
    const html = try scratch.dir.readFile(std.testing.io, "index.html", &buffer);
    try std.testing.expectEqualStrings("<h1>Recovered homepage</h1>", html);
}
