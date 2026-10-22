//! The apps the browser build serves: read from the project's `apps/` folder, whose files
//! the worker keeps in OPFS, or the module's own when the folder holds none; read again when
//! the `apps` operations ask, as `serve` does.
const std = @import("std");
const publr = @import("publr");

const apps = publr.apps;

/// The project's own folder, beside where it runs, whatever the build's apps came from.
pub const dir = "apps";
const base_options: apps.Options = .{};
const base_url_default = base_options.base_url;

pub const Host = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    project: *publr.routes.Project,
    index: *publr.lib.deps.Index,
    source: ?apps.folder.Apps = null,
    loaded: []apps.App = &.{},
    reason: publr.report.Reason = .{},
    /// The project's address as the apps' pages write it: the worker's scope.
    base_url: []const u8 = base_url_default,

    pub fn open(host: *Host) !void {
        std.debug.assert(host.loaded.len == 0);
        std.debug.assert(host.source == null);

        host.reason = .{};

        var source = try apps.folder.project_apps(host.gpa, host.io, dir, &host.reason);
        errdefer source.deinit();

        const loaded = try host.gpa.alloc(apps.App, source.specs.len);
        errdefer host.gpa.free(loaded);

        const now_ms = publr.sdk.context.wall_clock_ms(host.io);

        try apps.load.open(host.project, source.specs, loaded, host.gpa, host.index, now_ms, .{
            .base_url = host.base_url,
            // Their `public/` files are the project's, as `serve` reads them.
            .apps_dir = apps.folder.resolve_dir(host.io, base_options.apps_dir),
            .diagnostic = &host.reason,
        });
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

    /// The apps opened again at `address` (`https://publr.app/demo`), which the links their
    /// pages write and the admin's way to each app carry. It stays the caller's.
    /// Apps that will not open answer 503 saying why, as on a reload.
    pub fn serve_at(host: *Host, address: []const u8) void {
        std.debug.assert(std.mem.indexOf(u8, address, "://") != null);
        std.debug.assert(host.project.connection.transaction_depth == 0);

        host.base_url = address;
        _ = reload(host);
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

        host.project.apps_reason = "";

        host.open() catch |err| {
            host.project.apps_failed = true;
            host.project.apps_reason = host.failure(err);

            return host.project.apps_reason;
        };

        return null;
    }

    /// Why the apps would not open, for the 503 the site answers in its place.
    pub fn failure(host: *Host, err: anyerror) []const u8 {
        std.debug.assert(host.reason.len <= host.reason.buffer.len);
        std.debug.assert(host.project.apps_failed or host.loaded.len == 0);

        return if (host.reason.len > 0) host.reason.text() else @errorName(err);
    }
};
