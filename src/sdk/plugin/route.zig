//! HTTP routes a compiled-in plugin answers: each under a prefix the plugin owns,
//! `/admin/<own>`, `/api/<own>` or `/auth/<own>`, where `<own>` is its name or one of its
//! namespaces, so no two plugins, and no plugin and the core, answer the same path.
const std = @import("std");
pub const http = @import("../../lib/http.zig");

pub const routes_max: u32 = 16;
pub const areas = [_][]const u8{ "/admin/", "/api/", "/auth/" };

pub const Method = enum { get, post };
pub const Handler = *const fn (*http.Request, *http.Response, *http.Context) http.Error!void;

pub const Route = struct {
    method: Method = .get,
    /// `/api/<own>/...`; `:name` segments after the prefix are parameters.
    path: []const u8,
    handler: Handler,
};

/// A route with the plugin that declares it and the prefix it owns (`/api/sampler`).
pub const Declared = struct { owner: []const u8, prefix: []const u8, route: Route };

/// The routes a plugin declares, each checked: under a prefix it owns, at most
/// `routes_max`, none twice.
pub fn routes_of(comptime Plugin: type, comptime owned: []const []const u8) []const Declared {
    comptime {
        const name = Plugin.manifest.name;

        std.debug.assert(owned.len > 0);

        if (!@hasDecl(Plugin, "routes")) {
            return &.{};
        }

        const routes: []const Route = &Plugin.routes;

        if (routes.len == 0 or routes.len > routes_max) {
            @compileError("plugin " ++ name ++ ": `routes` holds 1 to 16 routes");
        }

        var list: []const Declared = &.{};

        for (routes) |route| {
            const prefix = prefix_of(route.path) orelse @compileError("plugin " ++ name ++
                ": route " ++ route.path ++ " is not under /admin/, /api/ or /auth/");

            if (!owns(owned, prefix)) {
                @compileError("plugin " ++ name ++ ": route " ++ route.path ++
                    " is under " ++ prefix ++ ", which is neither its name nor a namespace");
            }

            list = list ++ &[_]Declared{.{ .owner = name, .prefix = prefix, .route = route }};
        }

        return list;
    }
}

/// No two routes answer the same method and path.
pub fn assert_distinct(comptime declared: []const Declared) void {
    comptime {
        std.debug.assert(declared.len <= routes_max * 64);

        for (declared, 0..) |one, index| {
            for (declared[index + 1 ..]) |other| {
                const same = one.route.method == other.route.method and
                    std.mem.eql(u8, one.route.path, other.route.path);

                if (same) {
                    @compileError("plugins " ++ one.owner ++ " and " ++ other.owner ++
                        " both declare the route " ++ one.route.path);
                }
            }
        }
    }
}

pub const operator_commands_max: u32 = 8;

/// What the CLI next to a running server asks it, with the server's operator key:
/// `POST /_publr/<plugin>/<name>`. Only a process of this user on this machine has the key.
pub const OperatorCommand = struct { name: []const u8, handler: Handler };

/// An operator command at its path.
pub const DeclaredCommand = struct { owner: []const u8, path: []const u8, handler: Handler };

/// The operator commands a plugin declares, each at `/_publr/<plugin>/<name>`.
pub fn operator_commands_of(comptime Plugin: type) []const DeclaredCommand {
    comptime {
        const name = Plugin.manifest.name;

        std.debug.assert(name.len > 0);

        if (!@hasDecl(Plugin, "operator_commands")) {
            return &.{};
        }

        const commands: []const OperatorCommand = &Plugin.operator_commands;

        if (commands.len == 0 or commands.len > operator_commands_max) {
            @compileError("plugin " ++ name ++ ": `operator_commands` holds 1 to 8 commands");
        }

        var list: []const DeclaredCommand = &.{};

        for (commands, 0..) |command, index| {
            if (!plain_name(command.name)) {
                @compileError("plugin " ++ name ++ ": operator command " ++ command.name ++
                    " is lowercase letters, digits and `_`");
            }

            for (commands[index + 1 ..]) |other| {
                if (std.mem.eql(u8, command.name, other.name)) {
                    @compileError("plugin " ++ name ++ ": two operator commands " ++
                        command.name);
                }
            }

            list = list ++ &[_]DeclaredCommand{.{
                .owner = name,
                .path = "/_publr/" ++ name ++ "/" ++ command.name,
                .handler = command.handler,
            }};
        }

        return list;
    }
}

fn plain_name(comptime name: []const u8) bool {
    comptime {
        std.debug.assert(operator_commands_max > 0);

        if (name.len == 0 or name.len > 32) {
            return false;
        }

        for (name) |char| {
            const plain = std.ascii.isLower(char) or std.ascii.isDigit(char) or char == '_';

            if (!plain) {
                return false;
            }
        }

        return true;
    }
}

/// `/api/sampler` of `/api/sampler/greeting`: the area and the segment after it; null
/// when the path is under no area or names nothing after it.
pub fn prefix_of(path: []const u8) ?[]const u8 {
    std.debug.assert(path.len <= 1024);

    for (areas) |area| {
        if (!std.mem.startsWith(u8, path, area)) {
            continue;
        }

        const rest = path[area.len..];
        const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;

        if (end == 0 or rest[0] == ':') {
            return null;
        }

        return path[0 .. area.len + end];
    }

    return null;
}

/// Whether a core route with this pattern falls under `prefix`, which a plugin owns.
pub fn under(pattern: []const u8, prefix: []const u8) bool {
    std.debug.assert(prefix.len > 0);

    if (!std.mem.startsWith(u8, pattern, prefix)) {
        return false;
    }

    return pattern.len == prefix.len or pattern[prefix.len] == '/';
}

fn owns(comptime owned: []const []const u8, comptime prefix: []const u8) bool {
    comptime {
        const segment = prefix[std.mem.lastIndexOfScalar(u8, prefix, '/').? + 1 ..];

        std.debug.assert(segment.len > 0);

        for (owned) |name| {
            if (std.mem.eql(u8, name, segment)) {
                return true;
            }
        }

        return false;
    }
}

test "a route's prefix is its area and the segment after it" {
    try std.testing.expectEqualStrings("/api/sampler", prefix_of("/api/sampler/greeting").?);
    try std.testing.expectEqualStrings("/admin/sampler", prefix_of("/admin/sampler").?);
    try std.testing.expectEqualStrings("/auth/sampler", prefix_of("/auth/sampler/:id").?);
    try std.testing.expect(prefix_of("/sampler") == null);
    try std.testing.expect(prefix_of("/api/") == null);
    try std.testing.expect(prefix_of("/api/:namespace/x") == null);
    try std.testing.expect(under("/api/sampler/x", "/api/sampler"));
    try std.testing.expect(under("/api/sampler", "/api/sampler"));
    try std.testing.expect(!under("/api/samplers", "/api/sampler"));
    try std.testing.expect(!under("/api/:namespace/:verb", "/api/sampler"));
}
