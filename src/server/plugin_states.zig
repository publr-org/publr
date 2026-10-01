//! Every compiled-in plugin's `State`, made once when the server opens the project, freed
//! when it closes; what a context, a route or a hook reaches it through.
const std = @import("std");
const registry = @import("registry.zig");
const sdk = @import("../sdk.zig");
const state = @import("../sdk/plugin/state.zig");

const stateful = registry.stateful_plugins;

fn state_types() [stateful.len]type {
    var types: [stateful.len]type = undefined;

    std.debug.assert(types.len == stateful.len);

    for (stateful, &types) |Plugin, *State| {
        State.* = Plugin.State;
    }

    return types;
}

pub const States = struct {
    values: std.meta.Tuple(&state_types()),

    /// Each state made in plugin order; one that fails unmakes those made before it.
    pub fn init(states: *States, process: state.Process) !void {
        std.debug.assert(process.db_path.len > 0);

        var made: u32 = 0;

        errdefer states.deinit_first(made);

        inline for (stateful, 0..) |Plugin, index| {
            const value = &states.values[index];

            if (@hasDecl(Plugin.State, "init")) {
                try value.init(process);
            } else {
                value.* = .{};
            }

            made += 1;
        }

        std.debug.assert(made == stateful.len);
    }

    pub fn deinit(states: *States) void {
        std.debug.assert(stateful.len == states.values.len);

        states.deinit_first(stateful.len);
    }

    fn deinit_first(states: *States, count: u32) void {
        std.debug.assert(count <= stateful.len);

        inline for (stateful, 0..) |Plugin, index| {
            if (index < count and @hasDecl(Plugin.State, "deinit")) {
                states.values[index].deinit();
            }
        }
    }
};

/// A plugin's state, through what a context carries.
pub fn of(ctx: *const sdk.Ctx, comptime Plugin: type) *Plugin.State {
    std.debug.assert(ctx.now_ms >= 0);

    return from(ctx.plugin_states orelse @panic("no plugin states in this context"), Plugin);
}

/// A plugin's state, through the opaque pointer a project or a context carries.
pub fn from(states: *anyopaque, comptime Plugin: type) *Plugin.State {
    const index = comptime index_of(Plugin);
    const typed: *States = @ptrCast(@alignCast(states));

    return &typed.values[index];
}

fn index_of(comptime Plugin: type) u32 {
    comptime {
        for (stateful, 0..) |Candidate, index| {
            if (Candidate == Plugin) {
                return index;
            }
        }

        @compileError("plugin " ++ Plugin.manifest.name ++ " keeps no `State`");
    }
}
