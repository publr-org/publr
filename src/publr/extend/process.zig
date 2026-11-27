//! What a built-in plugin does to the process around the operations: take a command before
//! it runs (`host.before_command`) and act once `serve` listens (`host.serving`).
const std = @import("std");

/// What a plugin's `State.init` is given as the process starts.
pub const Process = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// Freed when the process ends; for what the state keeps.
    arena: std.mem.Allocator,
    db_path: [:0]const u8,
    /// Publr's own: the database library's process-wide state.
    runtime: *anyopaque,

    /// Opens databases besides the call's own: another copy's, by its path.
    pub fn databases(process: Process) @import("database.zig").Databases {
        return .{
            .runtime = process.runtime,
        };
    }
};

/// A command before it runs. A hook may move the process into another folder and take its
/// own arguments off `args`; what is left runs as the command, against `db_path`.
pub const Command = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    args: []const []const u8,
    db_path: [:0]const u8,
};

/// `serve`, listening: the port it got, every plugin's state, and the server itself.
pub const Serving = struct {
    io: std.Io,
    /// Lives as long as the server.
    arena: std.mem.Allocator,
    port: u16,
    /// Publr's own: every plugin's state, as the server keeps it.
    states: ?*anyopaque,
    /// Publr's own: the server.
    server: *anyopaque,

    /// The server, kept by a plugin's `State` to act on later (`Server.reload_apps`).
    pub fn served(serve: Serving) Server {
        return .{
            .held = serve.server,
        };
    }

    /// The state the built-in plugin `Plugin` keeps for the life of the process; null when
    /// the server keeps none.
    pub fn state(serve: Serving, comptime Plugin: type) ?*State(Plugin) {
        const states = serve.states orelse return null;

        return @import("../../server/plugin_states.zig").from(states, Plugin);
    }
};

fn State(comptime Plugin: type) type {
    return @import("../../server/plugin_states.zig").StateOf(Plugin);
}

/// The server `serve` runs, as a built-in plugin acts on it.
pub const Server = struct {
    /// Publr's own.
    held: *anyopaque,

    fn project(server: Server) *Project {
        return @ptrCast(@alignCast(server.held));
    }

    /// The system's `publr.Ctx`, in `arena`: what the plugin calls operations with outside
    /// any request (`user.end_sessions` as the server starts).
    pub fn system(server: Server, arena: std.mem.Allocator) error{OutOfMemory}!*Ctx {
        const identity = @import("../../adapters/rest/identity.zig");
        const inner = try arena.create(@import("../../sdk.zig").Ctx);
        const host = try arena.create(@import("../../sdk/plugin/context.zig").HostApi);

        inner.* = identity.context(server.project(), arena, .system);
        host.* = .{
            .inner = inner,
        };

        std.debug.assert(inner.caller == .system);

        return host.ctx();
    }

    /// The apps read again from their folder: after the plugin wrote them.
    pub fn reload_apps(server: Server) !void {
        const apps = server.project().apps_host orelse return;

        try apps.reload();
    }

    /// The name of the cookie this server keeps a sign-in in: one of its own, so a sign-in
    /// here is not one on another server of the same host. Lives as long as the server.
    pub fn set_session_cookie(server: Server, name: []const u8) void {
        std.debug.assert(name.len > 0);

        server.project().session_cookie = name;
    }
};

const Project = @import("../../server/project.zig").Project;
const Ctx = @import("../ctx.zig").Ctx;
