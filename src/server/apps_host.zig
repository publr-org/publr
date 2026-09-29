//! The apps `serve` holds: read from the project's folder (or, with none there, the
//! binary's own), loaded, and loaded again when `publr apps load` asks, without a restart.
//! An app that does not load affects the apps, never the CMS or its repair tools.
const std = @import("std");
const report = @import("../lib/report.zig");
const routes = @import("routes.zig");
const apps_adapter = @import("../adapters/apps.zig");
const sdk = @import("../sdk.zig");
const build_command = @import("build.zig");
const Index = @import("../lib/deps.zig").Index;

/// How the apps are served: their options, and `--static` (with `--full`).
pub const Mode = struct {
    options: apps_adapter.Options,
    static: bool = false,
    full: bool = false,
};

pub const AppsHost = struct {
    gpa: std.mem.Allocator,
    index: *Index,
    project: *routes.Project,
    mode: Mode,
    source: ?apps_adapter.folder.Apps = null,
    apps: []apps_adapter.App = &.{},
    reason: report.Reason = .{},
    /// The folder the apps were last read from.
    dir: []const u8 = "",

    /// At startup: a failure is a warning, the admin stays up.
    pub fn start(host: *AppsHost) void {
        std.debug.assert(host.project.apps.len == 0);

        host.open() catch |err| {
            host.project.apps_failed = true;
            report.warn_reason(
                host.reason.text(),
                "publr serve: the apps are unavailable: {s}; the admin stays up at /admin",
                .{@errorName(err)},
            );
        };
    }

    /// The apps read from the folder again and swapped in: on a failure, why, in `reason`,
    /// and the apps unavailable until a load succeeds.
    pub fn reload(host: *AppsHost) !void {
        std.debug.assert(host.project.connection.transaction_depth == 0);

        host.close();
        host.project.apps_failed = false;

        host.open() catch |err| {
            host.project.apps_failed = true;
            return err;
        };
    }

    /// Every app loaded and validated, then: `--static` brings each app's build up to date
    /// now (or builds it whole under `--full`), `--dev` serves nothing from a build, and
    /// otherwise an existing build under `--out` is what is served.
    fn open(host: *AppsHost) !void {
        std.debug.assert(host.apps.len == 0);

        var options = host.mode.options;

        options.apps_dir = apps_adapter.folder.resolve_dir(host.project.io, options.apps_dir);
        host.dir = options.apps_dir;
        options.diagnostic = &host.reason;
        host.source = try apps_adapter.folder.project_apps(
            host.gpa,
            host.project.io,
            options.apps_dir,
            &host.reason,
        );

        const specs = host.source.?.specs;

        if (specs.len == 0) {
            return;
        }

        host.apps = try host.gpa.alloc(apps_adapter.App, specs.len);

        const now_ms = sdk.context.wall_clock_ms(host.project.io);

        const project = host.project;
        const apps = host.apps;

        try apps_adapter.load.open(project, specs, apps, host.gpa, host.index, options, now_ms);
        try host.serve_builds();
    }

    fn serve_builds(host: *AppsHost) !void {
        std.debug.assert(host.project.apps.len == host.apps.len);

        if (host.mode.static) {
            const refreshed = try build_command.bring_up_to_date(host.project, host.mode.full);

            build_command.announce(refreshed, host.mode.options.output_dir);
        } else if (host.mode.options.dev) {
            std.debug.print("publr: --dev: rendering every page live, nothing cached\n", .{});
        } else {
            var served: u32 = 0;

            for (host.project.apps) |*app| {
                app.open_existing_output();

                if (app.output != null) {
                    served += 1;
                }
            }

            if (served == 0) {
                std.debug.print("publr: no ./{s}/, rendering the apps on request; " ++
                    "`publr build` makes them static\n", .{host.mode.options.output_dir});
            }
        }
    }

    pub fn close(host: *AppsHost) void {
        std.debug.assert(host.apps.len <= apps_adapter.spec.apps_max);

        apps_adapter.load.close(host.project);

        if (host.apps.len > 0) {
            host.gpa.free(host.apps);
            host.apps = &.{};
        }

        if (host.source) |*source| {
            source.deinit();
            host.source = null;
        }
    }
};
