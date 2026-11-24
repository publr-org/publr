//! A command sent from another machine: the `publr` command (`publr --site <address>
//! <command>`) posts its words to `/api/cli` with a device's token, and this Publr runs them
//! as that device through the same CLI. The words are read here, not there, so a project's
//! plugins answer with their own commands whoever asks, from wherever.
const std = @import("std");
const http = @import("../lib/http.zig");
const cli = @import("../adapters/cli.zig");
const identity_module = @import("../adapters/rest/identity.zig");
const registry = @import("registry.zig");
const sdk = @import("../sdk.zig");
const Project = @import("project.zig").Project;

pub const route = "/api/cli";
const body_bytes_max: u32 = 1 << 20;

pub const Envelope = struct {
    args: []const []const u8,
};
pub const Answer = struct {
    code: u8,
    out: []const u8,
    err: []const u8,
    /// The name of the failure it ended with, empty for none.
    failure: []const u8 = "",
};
/// An answer without a failure's name, as every Publr answered before it had one.
const Plain = struct {
    code: u8,
    out: []const u8,
    err: []const u8,
};
/// `POST /api/cli`: a device's command, run as the device; answered with its exit code,
/// output and errors. Anyone else is told to sign in.
pub fn handle(
    request: *http.Request,
    response: *http.Response,
    ctx: *http.Context,
) http.Error!void {
    std.debug.assert(ctx.user_data != null);
    std.debug.assert(request.method() == .post);

    const project = Project.of(ctx);
    const identity = identity_module.identify(request, ctx.arena, project);

    if (identity.caller != .token) {
        return response.json(.unauthorized, .{
            .@"error" = "device_required",
            .message = "Sign in with `publr login <address>` first",
        });
    }

    if (request.body.len > body_bytes_max) {
        return response.json(.payload_too_large, .{
            .@"error" = "too_large",
        });
    }

    const envelope = std.json.parseFromSliceLeaky(Envelope, ctx.arena, request.body, .{
        .ignore_unknown_fields = true,
    }) catch {
        return response.json(.bad_request, .{
            .@"error" = "invalid_body",
        });
    };

    if (envelope.args.len == 0) {
        return response.json(.bad_request, .{
            .@"error" = "invalid_body",
        });
    }

    const answer = try run_in(project, ctx.arena, identity.caller, envelope.args);

    // Named only when there is one: a CLI from before `failure` reads the plain answer.
    if (answer.failure.len == 0) {
        return response.json(.ok, Plain{
            .code = answer.code,
            .out = answer.out,
            .err = answer.err,
        });
    }

    try response.json(.ok, answer);
}

/// A command's words run here as `device`, through the same CLI as on this machine: its
/// exit code, output and errors. What `/api/cli` and MCP's `run` answer.
pub fn run_words(
    project: *const Project,
    arena: std.mem.Allocator,
    device: sdk.Caller,
    args: []const []const u8,
) error{OutOfMemory}!Answer {
    std.debug.assert(device == .token);
    std.debug.assert(args.len > 0);

    var out: std.Io.Writer.Allocating = .init(arena);
    var err: std.Io.Writer.Allocating = .init(arena);
    var failed: []const u8 = "";
    const code = cli.CLI(registry.SDK).run(
        project.connection,
        project.io,
        arena,
        project.auth,
        args,
        &out.writer,
        .{
            .now_ms = project.now_ms(),
            .test_clock = project.test_clock(),
            .err = &err.writer,
            .sandboxed_plugins = project.sandboxed_plugins,
            .scratch = project.scratch,
            .call_scratch = project.call_scratch,
            .plugin_memory = project.plugin_memory,
            .plugin_states = project.plugin_states,
            .files = project.files,
            .apps = project.apps_folder(),
            .agents = project.agents,
            .live = project.live,
            .updater = project.updater,
            .translations = if (project.languages) |languages| languages.view() else null,
            .device = device,
            .failed = &failed,
        },
    ) catch |failure| blk: {
        err.writer.print("publr: {s}\n", .{@errorName(failure)}) catch {
            return error.OutOfMemory;
        };
        break :blk 1;
    };

    return .{
        .code = code,
        .out = out.written(),
        .err = err.written(),
        .failure = failed,
    };
}

/// A command's words as `run_words`, in the copy of this site they name first (`--env <name>`),
/// if they do. That copy is another process with its own database: run through this binary,
/// in this folder, as the device.
pub fn run_in(
    project: *const Project,
    arena: std.mem.Allocator,
    device: sdk.Caller,
    args: []const []const u8,
) error{OutOfMemory}!Answer {
    std.debug.assert(device == .token);
    std.debug.assert(args.len > 0);

    if (args.len < 3 or !std.mem.eql(u8, args[0], "--env")) {
        return run_words(project, arena, device, args);
    }

    const list = registry.copies_list orelse return refused("This site has no copies");
    const dot = std.mem.indexOfScalar(u8, list, '.').?;
    const words = [_][]const u8{ list[0..dot], list[dot + 1 ..] };
    const listed = try run_words(project, arena, device, &words);

    if (listed.code != 0) {
        return listed;
    }

    const parsed = std.json.parseFromSliceLeaky(Copies, arena, listed.out, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return refused("The copies could not be read");
    const copy = copy_named(parsed.environments, args[1]) orelse {
        return refused("No environment, branch or alias of that name");
    };

    if (copy.current) {
        return run_words(project, arena, device, args[2..]);
    }

    if (project.binary.len == 0 or project.db_path.len == 0) {
        return refused("Copies cannot be reached from here");
    }

    return run_copy(project, arena, device.token.id, copy.name, args[2..]);
}

fn refused(text: []const u8) error{OutOfMemory}!Answer {
    std.debug.assert(text.len > 0);

    return .{
        .code = 1,
        .out = "",
        .err = text,
    };
}

const copy_output_bytes_max: u32 = 16 << 20;

fn run_copy(
    project: *const Project,
    arena: std.mem.Allocator,
    device_id: []const u8,
    copy: []const u8,
    args: []const []const u8,
) error{OutOfMemory}!Answer {
    std.debug.assert(device_id.len > 0);
    std.debug.assert(copy.len > 0);

    const head = [_][]const u8{
        project.binary, "--db",     project.db_path, "--env",
        copy,           "--device", device_id,
    };
    const argv = try std.mem.concat(arena, []const u8, &.{ &head, args });
    const ran = std.process.run(arena, project.io, .{
        .argv = argv,
        .cwd = .{
            .path = project.folder,
        },
        .stdout_limit = .limited(copy_output_bytes_max),
        .stderr_limit = .limited(copy_output_bytes_max),
    }) catch return refused("The copy could not be reached");
    const code: u8 = switch (ran.term) {
        .exited => |exited| exited,
        else => 1,
    };

    return .{
        .code = code,
        .out = ran.stdout,
        .err = ran.stderr,
    };
}

/// One copy as `environments list` and `open` answer it: what `--env` needs.
pub const Copy = struct {
    name: []const u8,
    aliases: []const []const u8 = &.{},
    address: []const u8 = "",
    current: bool = false,
};
pub const Copies = struct {
    environments: []const Copy,
};

/// The copy called `name`, by its slug or an alias; null when none is.
pub fn copy_named(copies: []const Copy, name: []const u8) ?Copy {
    std.debug.assert(name.len > 0);

    for (copies) |copy| {
        if (std.mem.eql(u8, copy.name, name)) {
            return copy;
        }

        for (copy.aliases) |alias| {
            if (std.mem.eql(u8, alias, name)) {
                return copy;
            }
        }
    }

    return null;
}
