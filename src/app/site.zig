const std = @import("std");
const db = @import("../lib/db.zig");
const http = @import("../lib/http.zig");
const auth_state = @import("../lib/auth.zig");
const site_state = @import("../adapters/site/state.zig");
const sdk = @import("../sdk.zig");
const registry = @import("registry.zig");
const middleware = @import("../adapters/site/middleware.zig");

/// What every HTTP handler reaches through `ctx.user_data`: the open database, the
/// process's auth state, the io the operations run on, the folder of the browser build
/// when serving it, and the public site once `serve` has loaded the theme.
pub const Site = struct {
    connection: *db.Db,
    auth: *auth_state.State,
    io: std.Io,
    static_dir: ?[]const u8 = null,
    public: ?*site_state.Public = null,
    public_failed: bool = false,
    /// Asked before the public site delivers a page or an island: the plugins' gates.
    delivery_gates: []const sdk.delivery.Gate = registry.plugins.merged_delivery_gates,
    /// Asked before anything else on the site's paths: the theme's `middleware.zig`.
    middleware: ?middleware.Middleware = middleware.theme,

    pub fn of(ctx: *const http.Context) *Site {
        std.debug.assert(ctx.user_data != null);

        const site: *Site = @ptrCast(@alignCast(ctx.user_data.?));

        std.debug.assert(site.connection.transaction_depth == 0);

        return site;
    }
};
