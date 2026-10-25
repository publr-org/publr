const std = @import("std");
const db = @import("../lib/db.zig");
const http = @import("../lib/http.zig");
const auth_state = @import("../lib/auth.zig");
const apps_state = @import("../adapters/apps/state.zig");
const model_app = @import("../model/app.zig");
const sdk = @import("../sdk.zig");
const registry = @import("registry.zig");
const outside_model = @import("../model/outside.zig");
const egress_model = @import("../model/egress.zig");

const App = apps_state.App;

/// What `-Dapps-max` may be at most.
pub const apps_limit: u32 = 1024;

/// What every HTTP handler reaches through `ctx.user_data`: the open database, the
/// process's auth state, the io the operations run on, the folder of the browser build
/// when serving it, and the apps once `serve` has loaded them.
pub const Project = struct {
    connection: *db.Db,
    auth: *auth_state.State,
    io: std.Io,
    static_dir: ?[]const u8 = null,
    /// Every compiled-in app, loaded; empty when the project has none or serves none.
    apps: []App = &.{},
    /// The apps failed to load: their paths answer 503 while the admin stays up.
    apps_failed: bool = false,
    /// Why, said on the 503 itself where whoever opens the site owns it (the browser build,
    /// in its own tab); empty on a server, whose visitors are not told.
    apps_reason: []const u8 = "",
    /// The host the apps' subdomains hang from: the project's address without its port.
    domain: []const u8 = "",
    /// The path the project is served under (`/environments/dev`, the path of `--url`);
    /// empty at the root. Requests arrive without it; every address sent back carries it.
    base: []const u8 = "",
    /// The folder `serve` runs in, absolute; empty outside `serve`.
    folder: []const u8 = "",
    /// How to run this server's own binary from `folder` (`./publr`); empty outside `serve`.
    binary: []const u8 = "",
    /// The apps as `serve` holds them, to load again when asked; null outside `serve`.
    apps_host: ?*@import("apps_host.zig").AppsHost = null,
    /// The apps folder of a host that is not `serve`: the browser build's, in OPFS.
    apps_elsewhere: ?sdk.context.AppsFolder = null,
    /// The key the CLI next to this server sends a command with (`operator.zig`); null when
    /// it takes none.
    operator_key: ?[]const u8 = null,
    /// Set when an operator command asked this server to stop; `serve` stops at its next
    /// tick.
    stop_requested: bool = false,
    /// Set with `stop_requested` when an update swapped the binary: `serve` becomes the new
    /// one once stopped.
    restart_requested: bool = false,
    /// `serve --auto-update patch`: looked at on every tick, acts once a day.
    auto_update: ?*@import("update.zig").Updater = null,
    /// The admin's languages, where a server built them; null: English only.
    languages: ?*@import("languages.zig").Languages = null,
    /// The rate limits a request's calls count against; null where nothing is limited.
    limits: ?*sdk.limits.Limits = null,
    /// The working memory every context made for a request shares; null where there is no
    /// server (a context then sets its own aside).
    scratch: ?*sdk.Scratch = null,
    /// The definitions a request has read, kept for it alone; null where there is no server.
    definitions: ?*sdk.DefinitionCache = null,
    /// The installed plugins installed, which every context made for a request carries.
    sandboxed_plugins: ?*const sdk.sandboxed_plugins.SandboxedPlugins = null,
    /// Every compiled-in plugin's `State` (`publr.plugin_states.from`), which every context
    /// made for a request carries.
    plugin_states: ?*anyopaque = null,
    /// The media library's files, which every context made for a request carries.
    files: ?@import("../lib/files.zig").Files = null,
    /// Building plugins from their sources, where `serve` carries the compiler.
    builder: ?sdk.context.PluginBuilder = null,
    /// Running a conversation's turn beside the server, where `serve` can.
    agents: ?sdk.context.AgentStarter = null,
    /// The workspaces watching conversations, told of each change.
    live: ?sdk.context.Live = null,
    /// Updating Publr in place, where `serve` can.
    updater: ?sdk.context.Updater = null,
    /// The session cookie's name; a plugin's `serving` may name another, so several servers
    /// on one host keep their sign-ins apart.
    session_cookie: []const u8 = @import("../adapters/rest/identity.zig").cookie_name,
    /// The readable signed-in hint beside the session (`identity.cookie_names`).
    hint_cookie: []const u8 = @import("../adapters/rest/identity.zig").hint_cookie_name,
    /// The visitor's id (`apps/visitor.zig`).
    visitor_cookie: []const u8 = @import("../adapters/apps/visitor.zig").cookie_name,
    /// On the site's host, who the toolbar is for (`split.zig`).
    member_cookie: []const u8 = @import("../adapters/rest/identity.zig").member_cookie_name,
    /// Where the admin answers when it is not on the site's host (`serve --admin-url`):
    /// `http://admin.localhost:8080`; empty when the admin is at `/admin` beside the site.
    admin_origin: []const u8 = "",
    /// The path the admin answers under on its host (`/spaces/ada/shop` on Publr Cloud, whose
    /// dashboard carries every project's admin); empty when it has none of its own. The proxy
    /// in front takes it off, as the HTTP layer takes `base` off.
    admin_base: []const u8 = "",
    /// The site's own origin, where the admin's host sends everything that is the site's.
    site_origin: []const u8 = "",
    /// Where plugins' outside calls may go, from the site's address (`outside_of`).
    outside: outside_model.Rule = .{},
    /// Asked before an app delivers a page or an island: the plugins' gates.
    delivery_gates: []const sdk.delivery.Gate = registry.native_plugins.merged_delivery_gates,

    pub fn of(ctx: *const http.Context) *Project {
        std.debug.assert(ctx.user_data != null);

        const project: *Project = @ptrCast(@alignCast(ctx.user_data.?));

        std.debug.assert(project.connection.transaction_depth == 0);

        return project;
    }

    /// The app a request is for, and its path inside the app.
    pub const Target = struct {
        app: *App,
        /// The path in the app, without the language's address.
        path: []const u8,
        /// The language the page is in, and its address (`/pl`), on a site with languages.
        place: @import("../model/variant.zig").Place = .{},
    };

    /// Which app answers `path` on `host`: the subdomain's app, else the longest path mount.
    pub fn resolve(project: *const Project, host: []const u8, path: []const u8) ?Target {
        std.debug.assert(path.len > 0);
        std.debug.assert(project.apps.len <= apps_limit);

        var mounts: [apps_limit]model_app.Mount = undefined;

        for (project.apps, 0..) |*app, index| {
            mounts[index] = app.spec.mount;
        }

        const mounts_len = project.apps.len;
        const found = model_app.resolve(mounts[0..mounts_len], project.domain, host, path);
        const resolved = found orelse return null;

        std.debug.assert(resolved.index < project.apps.len);

        return .{
            .app = &project.apps[resolved.index],
            .path = resolved.path,
        };
    }

    /// The domain the session cookie is set for, so one sign-in holds on every app: the
    /// project's domain when an app is mounted on a subdomain of it, and the domain is a
    /// name a browser shares cookies under (dotted, not an address). Null otherwise: the
    /// cookie stays the host's own.
    pub fn cookie_domain(project: *const Project) ?[]const u8 {
        std.debug.assert(project.apps.len <= apps_limit);
        std.debug.assert(project.domain.len <= model_app.host_len_max);

        const domain = project.domain;

        // A cookie for the domain would reach the admin's host too, which keeps its own.
        if (project.admin_origin.len > 0) {
            return null;
        }

        if (std.mem.indexOfScalar(u8, domain, '.') == null or address(domain)) {
            return null;
        }

        for (project.apps) |*app| {
            if (app.spec.mount == .subdomain) {
                return domain;
            }
        }

        return null;
    }

    /// Whether the admin answers on a host of its own, away from the site's.
    pub fn split(project: *const Project) bool {
        std.debug.assert(project.admin_origin.len <= model_app.host_len_max + 8);
        std.debug.assert(project.admin_origin.len == 0 or project.site_origin.len > 0);

        return project.admin_origin.len > 0;
    }

    /// The folder the `apps` operations reach: `serve`'s, else another host's, else none.
    pub fn apps_folder(project: *const Project) ?sdk.context.AppsFolder {
        std.debug.assert(project.apps.len <= apps_limit);

        if (project.apps_host) |host| {
            std.debug.assert(project.apps_elsewhere == null);
            return host.folder();
        }

        return project.apps_elsewhere;
    }

    /// The path every address the admin sends back carries: its own, else the project's.
    pub fn admin_path(project: *const Project) []const u8 {
        std.debug.assert(project.admin_base.len == 0 or project.admin_base[0] == '/');
        std.debug.assert(project.admin_base.len == 0 or project.split());

        return if (project.admin_base.len > 0) project.admin_base else project.base;
    }

    /// A request to the admin's own host; false when the admin has none.
    pub fn on_admin_host(project: *const Project, request: *const http.Request) bool {
        std.debug.assert(request.path().len > 0);

        if (!project.split()) {
            return false;
        }

        const host = request.header("host") orelse return false;

        return std.ascii.eqlIgnoreCase(host, model_app.host_of(project.admin_origin));
    }

    /// The loaded app of that name.
    pub fn find(project: *const Project, name: []const u8) ?*App {
        std.debug.assert(name.len > 0);
        std.debug.assert(project.apps.len <= apps_limit);

        for (project.apps) |*app| {
            if (std.mem.eql(u8, app.spec.name, name)) {
                return app;
            }
        }

        return null;
    }
};

/// An IPv4 address (digits and dots) or an IPv6 one (colons): never a cookie's domain.
fn address(host: []const u8) bool {
    std.debug.assert(host.len > 0);
    std.debug.assert(host.len <= model_app.host_len_max);

    for (host) |char| {
        const digit = char >= '0' and char <= '9';

        if (!digit and char != '.' and char != ':') {
            return false;
        }
    }

    return true;
}

test "the session cookie is shared across subdomains only for a named domain" {
    try std.testing.expect(address("127.0.0.1"));
    try std.testing.expect(address("::1"));
    try std.testing.expect(!address("example.com"));
}

/// The rule plugins' outside calls follow on a server whose site and admin answer at these
/// origins (either may be empty): their hosts are its own, and so are the public addresses
/// on the machine's interfaces; how calls leave is the host's (`PUBLR_EGRESS`). `serve` and
/// its queue worker both get it from here.
pub fn outside_of(
    arena: std.mem.Allocator,
    site_origin: []const u8,
    admin_origin: []const u8,
) error{OutOfMemory}!outside_model.Rule {
    std.debug.assert(site_origin.len <= 64 << 10);
    std.debug.assert(admin_origin.len <= 64 << 10);

    var hosts: std.ArrayList([]const u8) = .empty;

    for ([_][]const u8{ site_origin, admin_origin }) |origin| {
        const host = outside_model.host_of_origin(origin);

        if (host.len > 0) {
            try hosts.append(arena, host);
        }
    }

    var rule = outside_model.rule_of(registry.hosted, site_origin, hosts.items);

    rule.own_addresses = try @import("interfaces.zig").public(arena);
    rule.egress = egress_model.parse(@import("../lib/environment.zig").get(egress_model.variable));

    return rule;
}

test {
    _ = @import("interfaces.zig");
}
