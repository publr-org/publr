//! What compiled-in plugins do to the process around the operations: take a command before
//! it runs (`before_command`), act once `serve` listens (`serving`), and answer commands the
//! CLI next to a running server sends it (`operator_commands`, behind the operator key).
const std = @import("std");
const http = @import("../lib/http.zig");
const registry = @import("registry.zig");
const operator = @import("operator.zig");
const route = @import("../sdk/plugin/route.zig");
const Project = @import("project.zig").Project;

/// A command before it runs. A hook may move the process into another folder and take its
/// own arguments off `args`; what is left runs as the command, against `db_path`.
pub const Command = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    args: []const []const u8,
    db_path: [:0]const u8,
};

/// `serve`, listening: the project it serves, the port it got, and every plugin's state.
pub const Serving = struct {
    io: std.Io,
    /// Lives as long as the server.
    arena: std.mem.Allocator,
    project: *Project,
    port: u16,
};

/// Every plugin's `before_command`, in name order, each seeing what the one before left.
pub fn before_command(command: *Command) !void {
    std.debug.assert(command.db_path.len > 0);

    inline for (registry.before_command) |Plugin| {
        const Hook = @TypeOf(Plugin.before_command);

        comptime if (Hook != fn (*Command) anyerror!void) {
            @compileError("plugin " ++ Plugin.manifest.name ++ ": `before_command` is " ++
                "`pub fn before_command(command: *publr.plugin_hooks.Command) !void`");
        };

        try Plugin.before_command(command);
    }

    std.debug.assert(command.db_path.len > 0);
}

/// Every plugin's `serving`, in name order. One that fails stops `serve` before it answers
/// anything: a plugin that could not start is not half there.
pub fn serving(serve: Serving) !void {
    std.debug.assert(serve.port > 0);

    inline for (registry.serving) |Plugin| {
        const Hook = @TypeOf(Plugin.serving);

        comptime if (Hook != fn (Serving) anyerror!void) {
            @compileError("plugin " ++ Plugin.manifest.name ++ ": `serving` is " ++
                "`pub fn serving(serve: publr.plugin_hooks.Serving) !void`");
        };

        try Plugin.serving(serve);
    }
}

/// The operator commands at their paths, each answering only the key holder.
pub fn OperatorCommands(comptime declared: []const route.DeclaredCommand) type {
    return struct {
        pub const routes_count: u32 = declared.len;

        pub fn register(router: *http.Router) void {
            const before = router.routes_len;

            std.debug.assert(before + routes_count <= router.routes.len);

            inline for (declared) |command| {
                router.post(command.path, &Guarded(command.handler).handle);
            }

            std.debug.assert(router.routes_len == before + routes_count);
        }
    };
}

fn Guarded(comptime handler: route.Handler) type {
    return struct {
        fn handle(
            request: *http.Request,
            response: *http.Response,
            ctx: *http.Context,
        ) http.Error!void {
            std.debug.assert(ctx.user_data != null);

            if (!operator.authorized(request, Project.of(ctx))) {
                return response.text(.forbidden, "Forbidden");
            }

            return handler(request, response, ctx);
        }
    };
}
