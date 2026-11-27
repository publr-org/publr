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
const identity = @import("../adapters/rest/identity.zig");
const registry = @import("registry.zig");
const apps_watch = @import("apps_watch.zig");
const apps_interactive = @import("apps_interactive.zig");
const model_app = @import("../model/app.zig");
const addresses = model_app.addresses;
const outside = @import("../model/outside.zig");
const site_moves = @import("site_moves.zig");

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
    /// That folder as it was when they were read (`apps_watch`): 0 for none.
    stamp: u64 = 0,
    /// The site's own address as `addresses.zon` gave it at the last load, which the apps and
    /// `project.site_origin` point into; unused while the site stays at its `--url`.
    base_buffer: [addresses.url_len_max]u8 = undefined,
    base_len: u32 = 0,
    /// The hosts `project.outside` counts as the server's own, after a move.
    own_hosts: [outside.origins_max][]const u8 = undefined,
    /// What else follows a move while the server runs; none before it is set up.
    follower: ?site_moves.Follower = null,

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

    /// The apps read from the folder again and swapped in. A folder whose apps do not
    /// compile is refused first, the apps loaded before still serving: why, in `reason`.
    /// Any other failure leaves the apps unavailable until a load succeeds.
    pub fn reload(host: *AppsHost) !void {
        std.debug.assert(host.project.connection.transaction_depth == 0);

        try host.build_interactive();
        try host.check_folder();
        host.close();
        host.project.apps_failed = false;

        host.open() catch |err| {
            host.project.apps_failed = true;
            return err;
        };
    }

    /// The apps' interactive components built where they changed since (a merge or a push
    /// brings their sources, never what was built from them), as `serve` does when it starts.
    fn build_interactive(host: *AppsHost) !void {
        std.debug.assert(host.mode.options.apps_dir.len > 0);

        const db_path = host.project.db_path;

        if (db_path.len == 0) {
            return;
        }

        const io = host.project.io;
        var arena_state = std.heap.ArenaAllocator.init(host.gpa);
        defer arena_state.deinit();

        const dir = apps_adapter.folder.resolve_dir(io, host.mode.options.apps_dir);
        const place: apps_interactive.Place = .{
            .io = io,
            .arena = arena_state.allocator(),
        };

        if (!try apps_interactive.build_in(place, db_path, dir)) {
            host.reason.set("the apps' interactive components did not build", .{});
            return error.AppsRefused;
        }
    }

    /// What the apps' provider slots draw from: the compiled-in plugins' providers and
    /// components, and the installed ones'.
    fn slot_sources(
        host: *const AppsHost,
        arena: std.mem.Allocator,
    ) !apps_adapter.provider_slots.Sources {
        std.debug.assert(host.project.connection.transaction_depth == 0);

        return apps_adapter.provider_slots.sources(arena, host.project.sandboxed_plugins);
    }

    /// The folder's apps read and compiled aside, nothing swapped: an edit caught half
    /// done never takes the running apps down. Its stamp is kept, so the watch waits for
    /// the next change.
    fn check_folder(host: *AppsHost) !void {
        std.debug.assert(host.mode.options.apps_dir.len > 0);

        const io = host.project.io;
        const dir = apps_adapter.folder.resolve_dir(io, host.mode.options.apps_dir);
        var arena_state = std.heap.ArenaAllocator.init(host.gpa);
        defer arena_state.deinit();

        const arena = arena_state.allocator();
        const slots = try host.slot_sources(arena);
        const apps_folder = apps_adapter.folder;
        var source = apps_folder.project_apps(host.gpa, io, dir, &host.reason, slots) catch |err| {
            host.stamp = apps_watch.stamp_of(io, dir) orelse 0;
            return err;
        };
        defer source.deinit();

        if (try apps_adapter.check_specs(host.gpa, arena, source.specs)) |problem| {
            host.reason.set("{s}", .{problem});
            host.stamp = apps_watch.stamp_of(io, dir) orelse 0;
            return error.AppsRefused;
        }

        var options = host.mode.options;
        var kept: [addresses.entries_max]addresses.Entry = undefined;

        options.apps_dir = dir;
        _ = host.addresses_of(arena, &kept, options) catch |err| {
            host.stamp = apps_watch.stamp_of(io, dir) orelse 0;
            return err;
        };
    }

    /// This site's entries of `addresses.zon` at the top of the apps folder: the apps given
    /// an address of their own. None without the file; a broken one refuses the apps.
    fn addresses_of(
        host: *AppsHost,
        arena: std.mem.Allocator,
        kept: *[addresses.entries_max]addresses.Entry,
        options: apps_adapter.Options,
    ) ![]const addresses.Entry {
        std.debug.assert(options.apps_dir.len > 0);
        std.debug.assert(options.base_url.len > 0);

        const path = try std.fs.path.join(arena, &.{ options.apps_dir, "addresses.zon" });
        const limit: std.Io.Limit = .limited(64 << 10);
        const cwd = std.Io.Dir.cwd();
        const read = cwd.readFileAllocOptions(host.project.io, path, arena, limit, .of(u8), 0);
        const text = read catch |err| switch (err) {
            error.FileNotFound => return &.{},
            else => return err,
        };
        const entries = addresses.parse(arena, text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidAddresses => {
                host.reason.set("addresses.zon: an entry is not .site, .app and .url", .{});
                return error.AppsRefused;
            },
        };
        const own = addresses.of_site(entries, options.base_url, kept);

        if (addresses.problem(own, options.base_url)) |problem| {
            host.reason.set("addresses.zon: {s}", .{problem});
            return error.AppsRefused;
        }

        return own;
    }

    /// Where the site answers now: the address `addresses.zon` gives it, else its `--url`. The
    /// site's origin, which the admin's links to the site, sign-in and the tools' addresses
    /// read, follows it; a site with no admin of its own has none to follow.
    fn site_address(host: *AppsHost, own: []const addresses.Entry) []const u8 {
        std.debug.assert(host.mode.options.base_url.len > 0);

        const project = host.project;
        const started = host.mode.options.base_url;
        const given = addresses.base_of(own) orelse started;
        const moved = !std.ascii.eqlIgnoreCase(model_app.origin_of(given), project.site_origin);

        std.debug.assert(given.len <= host.base_buffer.len);

        @memcpy(host.base_buffer[0..given.len], given);
        host.base_len = @intCast(given.len);

        const kept = host.address();

        // A site with no admin of its own (the browser build) has no origin to follow.
        if (project.site_origin.len == 0 or !moved) {
            return kept;
        }

        const origins: outside.Origins = .{
            .site = model_app.origin_of(kept),
            .admin = project.admin_origin,
            .started = model_app.origin_of(started),
        };
        var rule = outside.rule_of(
            registry.hosted,
            origins.site,
            outside.hosts_of(origins, &host.own_hosts),
        );

        rule.own_addresses = project.outside.own_addresses;
        rule.egress = project.outside.egress;
        project.outside = rule;
        project.site_origin = origins.site;

        if (host.follower) |*follower| {
            follower.moved(kept, origins);
        }

        std.debug.assert(std.mem.eql(u8, kept, given));

        return kept;
    }

    /// The site's whole address now, its path included: where people and agents reach it.
    pub fn address(host: *const AppsHost) []const u8 {
        std.debug.assert(host.mode.options.base_url.len > 0);

        if (host.base_len == 0) {
            return host.mode.options.base_url;
        }

        return host.base_buffer[0..host.base_len];
    }

    /// Every app loaded and validated, then: `--static` brings each app's build up to date
    /// now (or builds it whole under `--full`), `--dev` serves nothing from a build, and
    /// otherwise an existing build under `--out` is what is served.
    fn open(host: *AppsHost) !void {
        std.debug.assert(host.apps.len == 0);

        var options = host.mode.options;

        options.apps_dir = apps_adapter.folder.resolve_dir(host.project.io, options.apps_dir);
        host.dir = options.apps_dir;
        host.stamp = apps_watch.stamp_of(host.project.io, host.dir) orelse 0;
        options.diagnostic = &host.reason;

        var arena_state = std.heap.ArenaAllocator.init(host.gpa);
        defer arena_state.deinit();

        var kept: [addresses.entries_max]addresses.Entry = undefined;

        options.addresses = try host.addresses_of(arena_state.allocator(), &kept, options);
        options.base_url = host.site_address(options.addresses);

        host.source = try apps_adapter.folder.project_apps(
            host.gpa,
            host.project.io,
            options.apps_dir,
            &host.reason,
            try host.slot_sources(arena_state.allocator()),
        );

        const specs = host.source.?.specs;

        if (specs.len == 0) {
            return;
        }

        host.apps = try host.gpa.alloc(apps_adapter.App, specs.len);

        const now_ms = sdk.context.wall_clock_ms(host.project.io);

        const project = host.project;
        const apps = host.apps;

        try apps_adapter.load.open(project, specs, apps, host.gpa, host.index, now_ms, options);
        try host.serve_builds();
        // Loaded from the folder: anything a CDN keeps of these apps may be stale now.
        apps_adapter.edge.publish_apps(project);
        host.announce(specs);
    }

    /// `apps.loaded` for each app, as the system: what a plugin recording structure changes
    /// sees when the folder's apps went live.
    fn announce(host: *AppsHost, specs: []const apps_adapter.spec.Spec) void {
        std.debug.assert(specs.len == host.apps.len);

        var arena_state = std.heap.ArenaAllocator.init(host.gpa);
        defer arena_state.deinit();

        var ctx = identity.context(host.project, arena_state.allocator(), .system);

        for (specs) |spec| {
            registry.SDK.announce(&ctx, sdk.AppsLoaded, .{
                .app = spec.name,
            });
        }
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

    /// What the `apps` operations reach: the folder, and `reload` with its reason.
    pub fn folder(host: *AppsHost) sdk.context.AppsFolder {
        std.debug.assert(host.mode.options.apps_dir.len > 0);

        const dir = if (host.dir.len > 0)
            host.dir
        else
            apps_adapter.folder.resolve_dir(host.project.io, host.mode.options.apps_dir);

        return .{
            .context = host,
            .dir = dir,
            .reload = &reload_reason,
        };
    }

    fn reload_reason(context: *anyopaque) ?[]const u8 {
        const host: *AppsHost = @ptrCast(@alignCast(context));

        std.debug.assert(host.apps.len <= apps_adapter.spec.apps_max);

        host.reload() catch |err| {
            return if (host.reason.len > 0) host.reason.text() else @errorName(err);
        };

        return null;
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

test {
    _ = apps_watch;
}
