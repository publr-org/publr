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

const routes = [_]publr.Host.Route{.{
    .path = "/api/sampler/port",
    .handler = &port,
}};

/// What the sampler keeps while the process runs.
pub const State = struct {
    db_path: []const u8 = "",
    port: u16 = 0,
    pings: u32 = 0,

    pub fn init(state: *State, process: publr.Host.Process) anyerror!void {
        std.debug.assert(process.db_path.len > 0);

        state.* = .{
            .db_path = try process.arena.dupe(u8, process.db_path),
        };
    }
};

const operator_commands = [_]publr.Host.OperatorCommand{
    .{
        .name = "ping",
        .handler = &ping,
    },
};

/// `publr --sampler-in <folder> <command>`: the command runs in that folder.
pub fn before_command(command: *publr.Host.Command) anyerror!void {
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
pub fn serving(serve: publr.Host.Serving) anyerror!void {
    std.debug.assert(serve.port > 0);

    const state = serve.state(Sampler) orelse return;

    state.port = serve.port;
}

/// `POST /_publr/sampler/ping`: the port `serve` noted, the database, and how many pings.
fn ping(
    request: *publr.Host.Request,
    response: *publr.Host.Response,
    ctx: *publr.Host.Context,
) publr.Host.HttpError!void {
    std.debug.assert(request.path().len > 0);

    const state = ctx.state(Sampler);

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

/// `GET /api/sampler/port`: the port `serve` noted, for a signed-in administrator.
fn port(
    request: *publr.Host.Request,
    response: *publr.Host.Response,
    ctx: *publr.Host.Context,
) publr.Host.HttpError!void {
    std.debug.assert(request.path().len > 0);

    const page = try publr.Host.admin_pages.require(request, response, ctx) orelse return;

    std.debug.assert(page.ctx().caller().signed_in());

    try response.json(.ok, .{
        .port = ctx.state(Sampler).port,
    });
}
