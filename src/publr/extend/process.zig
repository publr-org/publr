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
};

/// A command before it runs. A hook may move the process into another folder and take its
/// own arguments off `args`; what is left runs as the command, against `db_path`.
pub const Command = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    args: []const []const u8,
    db_path: [:0]const u8,
};

/// `serve`, listening: the port it got, and every plugin's state.
pub const Serving = struct {
    io: std.Io,
    /// Lives as long as the server.
    arena: std.mem.Allocator,
    port: u16,
    /// Publr's own: every plugin's state, as the server keeps it.
    states: ?*anyopaque,

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
