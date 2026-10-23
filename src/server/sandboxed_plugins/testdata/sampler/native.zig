//! What only a compiled-in sampler carries: a route, operator commands, a state and process
//! hooks. Each takes the host's own modules, which the sandbox lacks.
const std = @import("std");
const publr = @import("publr");

const Sampler = @import("main.zig");

/// What the sampler adds past the plugin API.
pub fn extend(host: *publr.Host) publr.Error!void {
    std.debug.assert(host.routes.len == 0);

    inline for (routes) |route| {
        try host.route(route);
    }

    inline for (operator_commands) |command| {
        try host.operator_command(command);
    }

    try host.state(State);
    try host.serving(serving);
    try host.before_command(before_command);
}

const routes = [_]publr.plugin.Route{.{
    .path = "/admin/sampler",
    .handler = &settings,
}};

/// What the sampler keeps while the process runs.
pub const State = struct {
    db_path: []const u8 = "",
    port: u16 = 0,
    pings: u32 = 0,

    pub fn init(state: *State, process: publr.plugin.Process) anyerror!void {
        std.debug.assert(process.db_path.len > 0);

        state.* = .{
            .db_path = try process.arena.dupe(u8, process.db_path),
        };
    }
};

const operator_commands = [_]publr.plugin.OperatorCommand{
    .{
        .name = "ping",
        .handler = &ping,
    },
};

/// `publr --sampler-in <folder> <command>`: the command runs in that folder.
pub fn before_command(command: *publr.plugin_hooks.Command) anyerror!void {
    std.debug.assert(command.db_path.len > 0);

    const args = command.args;

    if (args.len < 2 or !std.mem.eql(u8, args[0], "--sampler-in")) {
        return;
    }

    var dir = try std.Io.Dir.cwd().openDir(command.io, args[1], .{});
    defer dir.close(command.io);

    try std.process.setCurrentDir(command.io, dir);
    command.args = args[2..];
}

/// `serve` listening: the sampler notes where.
pub fn serving(serve: publr.plugin_hooks.Serving) anyerror!void {
    std.debug.assert(serve.port > 0);

    const states = serve.project.plugin_states orelse return;

    publr.plugin_states.from(states, Sampler).port = serve.port;
}

/// `POST /_publr/sampler/ping`: the port `serve` noted, the database, and how many pings.
fn ping(
    request: *publr.http.Request,
    response: *publr.http.Response,
    ctx: *publr.http.Context,
) publr.http.Error!void {
    std.debug.assert(request.path().len > 0);

    const project = publr.project.Project.of(ctx);
    const states = project.plugin_states orelse return response.text(.not_found, "Not Found");
    const state = publr.plugin_states.from(states, Sampler);

    state.pings += 1;

    try response.json(
        .ok,
        .{
            .port = state.port,
            .db_path = state.db_path,
            .pings = state.pings,
        },
    );
}

/// The log's operation as the core runs it.
fn Registered(comptime name: []const u8) type {
    const SDK = publr.registry.SDK;

    // Each operation's name compared once, a byte at a time.
    @setEvalBranchQuota(SDK.operations.len * publr.sdk.operation.name_len_max * 2);

    return SDK.find(name).?;
}

/// Settings › Sampler: the log, in the admin's own chrome.
fn settings(
    request: *publr.http.Request,
    response: *publr.http.Response,
    ctx: *publr.http.Context,
) publr.http.Error!void {
    std.debug.assert(request.path().len > 0);

    var session = try publr.admin.require(request, response, ctx) orelse return;
    const LogsRun = Registered("sampler.logs");
    const logged = publr.registry.SDK.dispatch(&session.ctx, LogsRun, .{}) catch |err| {
        return publr.admin.fail(&session, err, "/admin/settings");
    };

    try publr.admin.screen(&session, .ok, publr.admin.views.SamplerSettings, .{
        .lines = logged.lines,
        .port = try std.fmt.allocPrint(session.arena, "{d}", .{
            publr.plugin_states.of(&session.ctx, Sampler).port,
        }),
    }, .{});
}
