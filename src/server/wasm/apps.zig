//! The apps the browser build serves: read from the project's `apps/` folder, whose files
//! the worker keeps in OPFS, or the module's own when the folder holds none; read again when
//! the `apps` operations ask, as `serve` does.
const std = @import("std");
const publr = @import("publr");

const apps = publr.apps;

/// The project's own folder, beside where it runs, whatever the build's apps came from.
pub const dir = "apps";

pub const Host = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    project: *publr.routes.Project,
    index: *publr.lib.deps.Index,
    source: ?apps.folder.Apps = null,
    loaded: []apps.App = &.{},
    reason: publr.report.Reason = .{},

    pub fn open(host: *Host) !void {
        std.debug.assert(host.loaded.len == 0);
        std.debug.assert(host.source == null);

        host.reason = .{};

        var source = try apps.folder.project_apps(host.gpa, host.io, dir, &host.reason);
        errdefer source.deinit();

        const loaded = try host.gpa.alloc(apps.App, source.specs.len);
        errdefer host.gpa.free(loaded);

        const now_ms = publr.sdk.context.wall_clock_ms(host.io);

        try apps.load.open(host.project, source.specs, loaded, host.gpa, host.index, .{
            .diagnostic = &host.reason,
        }, now_ms);
        host.source = source;
        host.loaded = loaded;

        std.debug.assert(host.project.apps.len == host.loaded.len);
    }

    pub fn close(host: *Host) void {
        std.debug.assert(host.project.apps.len == host.loaded.len);

        apps.load.close(host.project);
        host.gpa.free(host.loaded);
        host.loaded = &.{};

        if (host.source) |*source| {
            source.deinit();
        }

        host.source = null;

        std.debug.assert(host.project.apps.len == 0);
    }

    /// What the `apps` operations reach: the folder, and `reload` with its reason.
    pub fn folder(host: *Host) publr.sdk.context.AppsFolder {
        std.debug.assert(dir.len > 0);
        std.debug.assert(host.reason.len <= host.reason.buffer.len);

        return .{
            .context = host,
            .dir = dir,
            .reload = &reload,
        };
    }

    fn reload(context: *anyopaque) ?[]const u8 {
        const host: *Host = @ptrCast(@alignCast(context));

        std.debug.assert(host.project.connection.transaction_depth == 0);

        host.close();
        host.project.apps_failed = false;

        std.debug.assert(host.project.apps.len == 0);

        host.open() catch |err| {
            host.project.apps_failed = true;
            return if (host.reason.len > 0) host.reason.text() else @errorName(err);
        };

        return null;
    }
};
