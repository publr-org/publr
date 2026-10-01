//! What a compiled-in plugin keeps for as long as the process runs: one `State`, made when
//! the server opens the project and handed to its operations, routes and hooks. A plugin
//! keeps state here, never in a top-level `var`.
const std = @import("std");
const db = @import("../../lib/db.zig");

/// What a plugin's `State.init` is given: the process's allocator for what lives as long as
/// it, the database's path, and the runtime every connection to it opens through.
pub const Process = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// Freed when the process ends; for what the state keeps.
    arena: std.mem.Allocator,
    db_path: [:0]const u8,
    runtime: *db.Runtime,
};

/// The plugins that keep a `State`, each checked: a struct, with `init` and `deinit` of the
/// shapes the server calls when it has them.
pub fn stateful(comptime plugins: anytype) []const type {
    comptime {
        var list: []const type = &.{};

        for (plugins) |Plugin| {
            if (!@hasDecl(Plugin, "State")) {
                continue;
            }

            check(Plugin);
            list = list ++ &[_]type{Plugin};
        }

        std.debug.assert(list.len <= plugins.len);

        return list;
    }
}

fn check(comptime Plugin: type) void {
    comptime {
        const State = Plugin.State;
        const name = Plugin.manifest.name;

        std.debug.assert(name.len > 0);

        if (@typeInfo(State) != .@"struct") {
            @compileError("plugin " ++ name ++ ": `State` is a struct");
        }

        const init_shape = fn (*State, Process) anyerror!void;

        if (@hasDecl(State, "init") and @TypeOf(State.init) != init_shape) {
            @compileError("plugin " ++ name ++ ": `State.init` is " ++
                "`pub fn init(state: *State, process: publr.plugin.Process) !void`");
        }

        if (@hasDecl(State, "deinit") and @TypeOf(State.deinit) != fn (*State) void) {
            @compileError("plugin " ++ name ++ ": `State.deinit` is " ++
                "`pub fn deinit(state: *State) void`");
        }

        if (!@hasDecl(State, "init") and std.meta.fields(State).len > 0) {
            for (std.meta.fields(State)) |field| {
                if (field.defaultValue() == null) {
                    @compileError("plugin " ++ name ++ ": `State` has no `init`, so its " ++
                        "field " ++ field.name ++ " needs a default");
                }
            }
        }
    }
}
