//! `publr apps load`: the project's apps read from its folder again and swapped into the
//! running server, so a changed template is live when the command returns. With no server
//! running, they are checked here, as `serve` would load them.
const std = @import("std");
const http = @import("../lib/http.zig");
const report = @import("../lib/report.zig");
const apps_adapter = @import("../adapters/apps.zig");
const operator = @import("operator.zig");
const Project = @import("project.zig").Project;

pub const route = "/_publr/apps/load";

const Answer = struct { loaded: u32 = 0, dir: []const u8 = "", @"error": ?[]const u8 = null };

pub fn run(init: std.process.Init, db_path: []const u8, args: []const []const u8) !u8 {
    std.debug.assert(db_path.len > 0);

    const named = parse(args) orelse {
        report.err("usage: publr apps load [--apps <dir>]", .{});
        return 2;
    };
    const arena = init.arena.allocator();

    if (try operator.find(init.io, arena, db_path)) |session| {
        if (named.len > 0) {
            report.err("publr apps load: the running server loads the folder it was started " ++
                "with (`serve --apps`); --apps only checks a folder while no server runs", .{});
            return 2;
        }

        const body = try operator.post(init, session, route, "{}");
        const answer = try std.json.parseFromSliceLeaky(Answer, arena, body, .{});

        return print(init, answer, "the running server");
    }

    const dir = apps_adapter.folder.resolve_dir(init.io, if (named.len > 0)
        named
    else
        apps_adapter.spec.public_dir);

    return print(init, try check_here(init, dir), "");
}

/// The folder `--apps` names, empty when none is named; null for anything else.
fn parse(args: []const []const u8) ?[]const u8 {
    std.debug.assert(args.len < 1 << 16);

    if (args.len == 0) {
        return "";
    }

    if (args.len == 2 and std.mem.eql(u8, args[0], "--apps") and args[1].len > 0) {
        return args[1];
    }

    return null;
}

/// With no server: the apps read and compiled as `serve` would, nothing swapped.
fn check_here(init: std.process.Init, dir: []const u8) !Answer {
    std.debug.assert(dir.len > 0);

    const arena = init.arena.allocator();
    var reason: report.Reason = .{};
    var source = apps_adapter.folder.project_apps(init.gpa, init.io, dir, &reason) catch |err| {
        const why = if (reason.len > 0) reason.text() else @errorName(err);

        return .{ .@"error" = try arena.dupe(u8, why) };
    };
    defer source.deinit();

    if (try apps_adapter.check_specs(init.gpa, arena, source.specs)) |problem| {
        return .{ .@"error" = problem };
    }

    return .{ .loaded = @intCast(source.specs.len), .dir = dir };
}

fn print(init: std.process.Init, answer: Answer, where: []const u8) !u8 {
    std.debug.assert(answer.loaded <= apps_adapter.spec.apps_max);

    if (answer.@"error") |problem| {
        report.err("publr apps load: {s}", .{problem});
        return 1;
    }

    const line = if (where.len > 0)
        try std.fmt.allocPrint(init.arena.allocator(), "{d} apps loaded in {s}, from {s}\n", .{
            answer.loaded,
            where,
            answer.dir,
        })
    else
        try std.fmt.allocPrint(init.arena.allocator(), "{d} apps load from {s}; no server " ++
            "runs, so nothing was swapped\n", .{ answer.loaded, answer.dir });

    try std.Io.File.stdout().writeStreamingAll(init.io, line);

    return 0;
}

/// `POST /_publr/apps/load`, from the CLI next to this server: the apps read and swapped in.
pub fn handle(
    request: *http.Request,
    response: *http.Response,
    ctx: *http.Context,
) http.Error!void {
    const project = Project.of(ctx);

    if (!operator.authorized(request, project)) {
        return response.text(.forbidden, "Forbidden");
    }

    const host = project.apps_host orelse return response.text(.not_found, "Not Found");

    std.debug.assert(host.project == project);

    host.reload() catch |err| {
        const why = if (host.reason.len > 0) host.reason.text() else @errorName(err);

        return response.json(.ok, Answer{ .@"error" = why });
    };

    try response.json(.ok, Answer{ .loaded = @intCast(host.apps.len), .dir = host.dir });
}
