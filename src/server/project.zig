const std = @import("std");
const db = @import("../lib/db.zig");
const http = @import("../lib/http.zig");
const auth_state = @import("../lib/auth.zig");
const apps_state = @import("../adapters/apps/state.zig");
const model_app = @import("../model/app.zig");
const sdk = @import("../sdk.zig");
const registry = @import("registry.zig");

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
    /// The host the apps' subdomains hang from: the project's address without its port.
    domain: []const u8 = "",
    /// The apps as `serve` holds them, to load again when asked; null outside `serve`.
    apps_host: ?*@import("apps_host.zig").AppsHost = null,
    /// The key the CLI next to this server sends a command with (`operator.zig`); null when
    /// it takes none.
    operator_key: ?[]const u8 = null,
    /// The installed plugins installed, which every context made for a request carries.
    sandboxed_plugins: ?*const sdk.sandboxed_plugins.SandboxedPlugins = null,
    /// Asked before an app delivers a page or an island: the plugins' gates.
    delivery_gates: []const sdk.delivery.Gate = registry.native_plugins.merged_delivery_gates,

    pub fn of(ctx: *const http.Context) *Project {
        std.debug.assert(ctx.user_data != null);

        const project: *Project = @ptrCast(@alignCast(ctx.user_data.?));

        std.debug.assert(project.connection.transaction_depth == 0);

        return project;
    }

    /// The app a request is for, and its path inside the app.
    pub const Target = struct { app: *App, path: []const u8 };

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

        return .{ .app = &project.apps[resolved.index], .path = resolved.path };
    }

    /// The domain the session cookie is set for, so one sign-in holds on every app: the
    /// project's domain when an app is mounted on a subdomain of it, and the domain is a
    /// name a browser shares cookies under (dotted, not an address). Null otherwise: the
    /// cookie stays the host's own.
    pub fn cookie_domain(project: *const Project) ?[]const u8 {
        std.debug.assert(project.apps.len <= apps_limit);
        std.debug.assert(project.domain.len <= model_app.host_len_max);

        const domain = project.domain;

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
