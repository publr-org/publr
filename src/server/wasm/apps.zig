//! The apps the browser build serves: read from the project's `apps/` folder, whose files
//! the worker keeps in OPFS, or the module's own when the folder holds none; read again when
//! the `apps` operations ask, as `serve` does.
const std = @import("std");
const publr = @import("publr");

const apps = publr.apps;

/// The project's own folder, beside where it runs, whatever the build's apps came from.
pub const dir = "apps";
/// The longest address the apps' links may be written under.
const base_url_bytes_max: u32 = 256;
const base_url_default = (apps.Options{}).base_url;

pub const Host = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    project: *publr.routes.Project,
    index: *publr.lib.deps.Index,
    source: ?apps.folder.Apps = null,
    loaded: []apps.App = &.{},
    reason: publr.report.Reason = .{},
    /// The project's address as the apps' pages write it: its path is the worker's base.
    base_url: []const u8 = base_url_default,
    base_url_buffer: [base_url_bytes_max]u8 = undefined,

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
            .base_url = host.base_url,
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

    /// The apps opened again under `base` (`/demo`), so the links their pages write carry it.
    pub fn serve_under(host: *Host, base: []const u8) !void {
        std.debug.assert(base.len > 0 and base[0] == '/');
        std.debug.assert(host.project.connection.transaction_depth == 0);

        host.base_url = try std.fmt.bufPrint(&host.base_url_buffer, "{s}{s}", .{
            base_url_default,
            base,
        });
        host.close();
        try host.open();
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
