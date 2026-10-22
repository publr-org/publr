const std = @import("std");
const sdk = @import("../sdk.zig");
const db = @import("../lib/db.zig");
const report = @import("../lib/report.zig");

pub const args_max: u32 = 128;
pub const value_len_max: u32 = 64 << 10;

pub const Error = sdk.Error || error{ UnknownOp, UnknownFlag, MissingValue, WriteFailed };

const runtime_cli = @import("cli/sandboxed_plugins.zig");
const help = sdk.help;

pub const Options = struct {
    now_ms: i64 = 0,
    err: ?*std.Io.Writer = null,
    password_env: ?[]const u8 = null,
    /// The installed plugins installed: their operations are commands too.
    sandboxed_plugins: ?*const sdk.sandboxed_plugins.SandboxedPlugins = null,
    /// Every compiled-in plugin's `State`, where a server made them.
    plugin_states: ?*anyopaque = null,
    /// The media library's files, where a server made them.
    files: ?@import("../lib/files.zig").Files = null,
    /// The project's apps, where a server holds them.
    apps: ?sdk.context.AppsFolder = null,
    /// Building plugins from their sources, where a server carries the compiler.
    builder: ?sdk.context.PluginBuilder = null,
    /// Running a conversation's turn beside the server, where one runs.
    agents: ?sdk.context.AgentStarter = null,
    live: ?sdk.context.Live = null,
    /// Updating Publr, where a server runs it.
    updater: ?sdk.context.Updater = null,
    /// Who runs every command, fixed: a device sending them from elsewhere (`/api/cli`).
    /// `--as` and `--as-admin` are refused then.
    device: ?sdk.Caller = null,
    /// The device's call said `--production` (`ctx.production`).
    production: bool = false,
    /// Where the name of the failure a command ended with goes, for an adapter that answers
    /// it: `/api/cli` passes it to the device.
    failed: ?*[]const u8 = null,
};

const AuthState = @import("../lib/auth.zig").State;

/// One command line's run: what it reads and writes, and how its caller asked for it.
const Invocation = struct {
    db: *db.Db,
    io: std.Io,
    arena: std.mem.Allocator,
    auth: *AuthState,
    options: Options,
};

pub const message_len_max: u32 = 512;

pub fn CLI(comptime SDK: type) type {
    return struct {
        pub fn run(
            database: *db.Db,
            io: std.Io,
            arena: std.mem.Allocator,
            auth: *AuthState,
            args: []const []const u8,
            out: *std.Io.Writer,
            options: Options,
        ) Error!u8 {
            std.debug.assert(database.transaction_depth == 0);

            const invocation: Invocation = .{
                .db = database,
                .io = io,
                .arena = arena,
                .auth = auth,
                .options = options,
            };

            return run_invocation(invocation, args, out);
        }

        fn run_invocation(
            invocation: Invocation,
            args: []const []const u8,
            out: *std.Io.Writer,
        ) Error!u8 {
            @setEvalBranchQuota(100_000);

            if (args.len > args_max) {
                return fail(invocation, "too many arguments");
            }

            for (args) |arg| {
                if (arg.len > value_len_max) return fail(invocation, "argument is too long");
            }

            std.debug.assert(invocation.db.transaction_depth == 0);

            var caller: sdk.Caller = invocation.options.device orelse .anonymous;
            var index: u32 = 0;

            while (index < args.len and std.mem.startsWith(u8, args[index], "-")) : (index += 1) {
                const flag = args[index];
                const acting_as = std.mem.eql(u8, flag, "--as-admin") or
                    std.mem.eql(u8, flag, "--as");

                if (acting_as and invocation.options.device != null) {
                    return fail(invocation, "a device acts as its own account; drop \"--as\"");
                }

                if (std.mem.eql(u8, flag, "--as-admin")) {
                    caller = .system;
                } else if (std.mem.eql(u8, flag, "--as")) {
                    index += 1;
                    if (index == args.len) {
                        return fail(invocation, "flag \"--as\" needs a user id or email");
                    }
                    caller = try resolve_user(invocation, args[index]) orelse return failf(
                        invocation,
                        "unknown user \"{s}\"; --as takes a user id or email",
                        .{args[index]},
                    );
                } else if (is_help_flag(flag)) {
                    try print_help(out);
                    return 0;
                } else if (std.mem.eql(u8, flag, "--commands")) {
                    const sandboxed = invocation.options.sandboxed_plugins;
                    @import("cli/commands.zig").print(SDK, sandboxed, out) catch
                        return error.WriteFailed;

                    return 0;
                } else {
                    return failf(invocation, "unknown flag \"{s}\"; run \"publr --help\"", .{flag});
                }
            }

            if (index == args.len) {
                try print_help(out);
                return 2;
            }

            if (std.mem.eql(u8, args[index], "init")) {
                var aliased: [args_max + 1][]const u8 = undefined;
                const rest = args[index + 1 ..];
                if (rest.len > args_max - 2) return fail(invocation, "too many arguments");

                aliased[0] = "project";
                aliased[1] = "init";
                @memcpy(aliased[2 .. 2 + rest.len], rest);

                return dispatch_command(invocation, caller, aliased[0 .. 2 + rest.len], out);
            }

            return dispatch_command(invocation, caller, args[index..], out);
        }

        fn dispatch_command(
            invocation: Invocation,
            caller: sdk.Caller,
            args: []const []const u8,
            out: *std.Io.Writer,
        ) Error!u8 {
            @setEvalBranchQuota(100_000);

            std.debug.assert(args.len > 0);
            std.debug.assert(args.len <= args_max);

            if (args[0].len == 0) {
                return fail(invocation, "command must not be empty");
            }

            const index: u32 = 0;
            const bare_namespace = std.mem.indexOfScalar(u8, args[index], '.') == null and
                (index + 1 == args.len or is_help_flag(args[index + 1]));

            if (bare_namespace) {
                if (!namespace_known(args[index])) {
                    if (invocation.options.sandboxed_plugins) |sandboxed| {
                        if (try runtime_cli.print_namespace_help(sandboxed, args[index], out)) {
                            return if (index + 1 == args.len) 2 else 0;
                        }
                    }

                    return failf(
                        invocation,
                        "unknown command \"{s}\"; commands are <namespace> <verb>, " ++
                            "run \"publr --help\"",
                        .{args[index]},
                    );
                }

                try print_namespace_help(args[index], out);

                return if (index + 1 == args.len) 2 else 0;
            }

            const name = operation_name(invocation.arena, args[index..]) catch |err| switch (err) {
                error.UnknownOp => return failf(
                    invocation,
                    "unknown command \"{s}\"; commands are <namespace> <verb>, " ++
                        "run \"publr --help\"",
                    .{args[index]},
                ),
                else => return err,
            };
            const rest = args[index + operation_name_args(args[index..]) ..];

            var ctx = sdk.Ctx.init(
                invocation.db,
                invocation.io,
                invocation.arena,
                invocation.auth,
                caller,
                .{
                    .now_ms = invocation.options.now_ms,
                },
            );

            ctx.sandboxed_plugins = invocation.options.sandboxed_plugins;
            ctx.plugin_states = invocation.options.plugin_states;
            ctx.files = invocation.options.files;
            ctx.apps = invocation.options.apps;
            ctx.builder = invocation.options.builder;
            ctx.agents = invocation.options.agents;
            ctx.live = invocation.options.live;
            ctx.updater = invocation.options.updater;
            ctx.production = invocation.options.production;

            inline for (SDK.operations) |Operation| {
                if (std.mem.eql(u8, Operation.name, name)) {
                    if (rest.len == 1 and is_help_flag(rest[0])) {
                        try help.command(Operation, out);
                        return 0;
                    }
                    const code = try invoke(&ctx, Operation, rest, out, invocation);

                    hand_on_events(&ctx);

                    return code;
                }
            }

            if (invocation.options.sandboxed_plugins) |sandboxed| {
                if (sandboxed.find(name)) |found| {
                    const code = try invoke_runtime(&ctx, found, rest, out, invocation);

                    hand_on_events(&ctx);

                    return code;
                }
            }

            const namespace = sdk.operation.namespace(name);

            if (namespace_known(namespace)) {
                return failf(invocation, "unknown command \"{s} {s}\"; run \"publr {s} --help\"", .{
                    namespace,
                    sdk.operation.verb(name),
                    namespace,
                });
            }

            return failf(invocation, "unknown command \"{s}\"; run \"publr --help\"", .{name});
        }

        fn namespace_known(namespace: []const u8) bool {
            @setEvalBranchQuota(100_000);

            std.debug.assert(namespace.len > 0);
            std.debug.assert(SDK.operations.len > 0);

            inline for (SDK.operations) |Operation| {
                if (std.mem.eql(u8, comptime sdk.operation.namespace(Operation.name), namespace)) {
                    return true;
                }
            }

            return false;
        }

        fn print_namespace_help(namespace: []const u8, out: *std.Io.Writer) Error!void {
            @setEvalBranchQuota(100_000);

            std.debug.assert(namespace.len > 0);
            std.debug.assert(SDK.operations.len > 0);

            out.print("Usage: publr {s} <verb> [--field value ...]\n", .{namespace}) catch
                return error.WriteFailed;

            inline for (SDK.namespaces) |documented| {
                if (std.mem.eql(u8, documented.name, namespace)) {
                    out.print("\n{s}\n\n{s}\n", .{ documented.summary, documented.details }) catch
                        return error.WriteFailed;
                }
            }

            write(out, "\nCommands:\n\n") catch return error.WriteFailed;

            inline for (SDK.operations) |Operation| {
                if (std.mem.eql(u8, comptime sdk.operation.namespace(Operation.name), namespace)) {
                    out.print("  {s} {s:<20} {s}\n", .{
                        namespace,
                        comptime sdk.operation.verb(Operation.name),
                        Operation.description,
                    }) catch return error.WriteFailed;
                }
            }

            const footer = "\nRun `publr {s} <verb> --help` for the fields of a command.\n";
            out.print(footer, .{namespace}) catch return error.WriteFailed;
        }

        /// Without a server next to it, the CLI hands the command's queued events to the
        /// `on` hooks itself once it has committed; in a server, the same.
        fn hand_on_events(ctx: *sdk.Ctx) void {
            std.debug.assert(ctx.db.transaction_depth == 0);
            std.debug.assert(passes_max > 0);

            const take_max = @import("../store/event_queue.zig").take_max;
            var passes: u32 = 0;

            while (passes < passes_max) : (passes += 1) {
                const handed = SDK.events.drain(ctx, take_max) catch |err| {
                    std.log.warn("events: not handed on: {t}", .{err});
                    return;
                };

                if (handed < take_max) {
                    return;
                }
            }
        }

        const passes_max: u32 = 1024;

        fn invoke(
            ctx: *sdk.Ctx,
            comptime Operation: type,
            args: []const []const u8,
            out: *std.Io.Writer,
            invocation: Invocation,
        ) Error!u8 {
            var problem: Problem = .{};
            const parse_options: ParseOptions = .{
                .password_env = invocation.options.password_env,
            };
            const in = parse_in(Operation.In, ctx.arena, args, &problem, parse_options) catch {
                return failf(invocation, "{s} {s}: {s}; run \"publr {s} {s} --help\"", .{
                    comptime sdk.operation.namespace(Operation.name),
                    comptime sdk.operation.verb(Operation.name),
                    problem.text(),
                    comptime sdk.operation.namespace(Operation.name),
                    comptime sdk.operation.verb(Operation.name),
                });
            };

            if (comptime sdk.operation.deprecation(Operation) != null) {
                const text = comptime sdk.operation.deprecation_text(Operation);

                std.debug.print("publr: {s}\n", .{text});
            }

            const result = SDK.dispatch(ctx, Operation, in) catch |err| {
                return refused(invocation, ctx, Operation.name, err);
            };

            std.json.Stringify.value(result, .{
                .whitespace = .indent_2,
            }, out) catch
                return error.WriteFailed;
            out.writeByte('\n') catch return error.WriteFailed;

            return 0;
        }

        /// An operation an installed plugin brings: flags read by its manifest's field shapes.
        fn invoke_runtime(
            ctx: *sdk.Ctx,
            found: sdk.sandboxed_plugins.Operation,
            args: []const []const u8,
            out: *std.Io.Writer,
            invocation: Invocation,
        ) Error!u8 {
            const namespace = sdk.operation.namespace(found.name);
            const verb = sdk.operation.verb(found.name);

            std.debug.assert(found.name.len > 0);

            if (args.len == 1 and is_help_flag(args[0])) {
                try runtime_cli.print_help(found, out);
                return 0;
            }

            var problem: Problem = .{};
            const input = runtime_cli.parse(ctx.arena, found, args, &problem) catch {
                return failf(invocation, "{s} {s}: {s}; run \"publr {s} {s} --help\"", .{
                    namespace, verb, problem.text(), namespace, verb,
                });
            };
            const result = SDK.call_json(ctx, found.name, input) catch |err| {
                return refused(invocation, ctx, found.name, err);
            };

            try runtime_cli.print_json(ctx.arena, result, out);

            return 0;
        }

        pub fn print_help(out: *std.Io.Writer) Error!void {
            @setEvalBranchQuota(100_000);

            comptime std.debug.assert(SDK.operations.len > 0);
            comptime std.debug.assert(help_header.len > 0);

            write(out, help_header) catch return error.WriteFailed;

            var previous_namespace: []const u8 = "";

            inline for (SDK.operations) |Operation| {
                const namespace = comptime sdk.operation.namespace(Operation.name);
                const verb = comptime sdk.operation.verb(Operation.name);

                if (!std.mem.eql(u8, namespace, previous_namespace)) {
                    if (previous_namespace.len != 0) {
                        write(out, "\n") catch return error.WriteFailed;
                    }

                    if (comptime SDK.namespace_of(namespace)) |documented| {
                        out.print("{s}: {s}\n\n", .{ namespace, documented.summary }) catch
                            return error.WriteFailed;
                    }

                    previous_namespace = namespace;
                }

                out.print("  {s} {s:<24} {s}\n", .{ namespace, verb, Operation.description }) catch
                    return error.WriteFailed;
            }

            write(out, help_footer) catch return error.WriteFailed;
        }
    };
}

const help_header =
    \\Usage: publr [--db <path>] [options] <namespace> <verb> [--field value ...]
    \\       publr init --email <email> --display_name <name>   first run: create the admin
    \\       publr serve [--port <n>]                            start the server
    \\       publr plugin build --name <name>                    build and install a plugin
    \\       publr apps load                                     load the apps' changes
    \\       publr zig <args>                                    the compiler for plugins
    \\       publr db check                                      what an update would find
    \\       publr backups | restore <name>                      the backups before each update
    \\       publr pack [<file>] | unpack <file>                 the whole site in one file
    \\       publr cloud deploy --space <s> --slug <address>     this site made a Cloud project
    \\
    \\An agent building on Publr: run `publr agents` first, and read all of it. Every command
    \\with its flags, on one line each: `publr --commands`.
    \\
    \\Options:
    \\
    \\  --db <path>        Database file (default: data/publr.db); must come first
    \\  --as <user>        Run as this user (id or email)
    \\  --as-admin         Run as the local operator, unrestricted
    \\  --version          Print version and exit
    \\  -h, --help         Print this help; after a command, print its fields
    \\
    \\Commands:
    \\
    \\
;

const help_footer =
    \\
    \\Run `publr <namespace> --help` to list a namespace, `publr <namespace> <verb> --help`
    \\for the fields of a command. Installed plugins bring namespaces of their own, not listed
    \\here: `publr --as-admin plugin list` names them, then `publr <namespace> --help`.
    \\
;

pub const Problem = struct {
    buffer: [message_len_max]u8 = undefined,
    len: u32 = 0,

    pub fn set(problem: *Problem, comptime format: []const u8, args: anytype) void {
        const written = report.format_bounded(&problem.buffer, format, args);
        problem.len = @intCast(written.len);

        std.debug.assert(problem.len <= message_len_max);
        std.debug.assert(problem.len > 0);
    }

    pub fn text(problem: *const Problem) []const u8 {
        std.debug.assert(problem.len <= message_len_max);
        return problem.buffer[0..problem.len];
    }
};

fn fail(invocation: Invocation, message: []const u8) u8 {
    std.debug.assert(message.len > 0);
    std.debug.assert(message.len <= message_len_max);

    if (invocation.options.err) |err| {
        err.print("publr: {s}\n", .{message}) catch |print_err| {
            std.debug.print("publr: {t}\n", .{print_err});
        };
    } else {
        report.err("publr: {s}", .{message});
    }

    return 2;
}

fn failf(invocation: Invocation, comptime format: []const u8, args: anytype) u8 {
    var buffer: [message_len_max]u8 = undefined;
    const message = report.format_bounded(&buffer, format, args);

    std.debug.assert(message.len > 0);
    std.debug.assert(message.len <= message_len_max);

    return fail(invocation, message);
}

/// The call's refusal, then each problem with the input on a line of its own under it:
/// `  --name: A name is 1 to 80 characters.`
fn refused(invocation: Invocation, ctx: *const sdk.Ctx, name: []const u8, err: sdk.Error) u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(ctx.problems.len <= sdk.operation.problems_max);

    const namespace = sdk.operation.namespace(name);
    const verb = sdk.operation.verb(name);
    var buffer: [message_len_max]u8 = undefined;
    var message: std.Io.Writer = .fixed(&buffer);

    note_failure(invocation, ctx);

    message.print("{s} {s}: {s}", .{ namespace, verb, describe(err, ctx) }) catch {
        return failf(invocation, "{s} {s}: {s}", .{ namespace, verb, describe(err, ctx) });
    };

    if (err == error.Invalid) {
        for (ctx.problems) |problem| {
            message.print("\n  --{s}: {s}", .{ problem.field, problem.message }) catch break;
        }
    }

    return fail(invocation, message.buffered());
}

fn note_failure(invocation: Invocation, ctx: *const sdk.Ctx) void {
    std.debug.assert(ctx.now_ms >= 0);

    const failure = ctx.failure orelse return;
    const failed = invocation.options.failed orelse return;

    std.debug.assert(failure.name.len > 0);

    failed.* = failure.name;
}

fn describe(err: sdk.Error, ctx: *const sdk.Ctx) []const u8 {
    std.debug.assert(@errorName(err).len > 0);

    const caller = ctx.caller;

    const text: []const u8 = switch (err) {
        error.Denied => if (caller == .anonymous)
            "denied for an anonymous caller; use --as <user> or --as-admin"
        else
            "denied for this caller",
        error.Invalid => "invalid input",
        error.NotFound => "not found",
        error.Conflict => "conflict: it already exists or was already done",
        error.Vetoed => "vetoed by a plugin",
        error.Throttled => "too many calls or failed attempts; wait before trying again",
        error.Failed => if (ctx.failure) |failure| failure.message else "failed",
        error.Unavailable => "a service it needs is unavailable; nothing changed, try again",
        error.BadCredentials => "wrong email or password",
        error.InvalidationFailed => "dependency invalidation failed; write rolled back",
        error.OutOfMemory => "out of memory",
        error.Busy => "database is busy, try again",
        error.Constraint => "database constraint violated",
        error.ReadOnly => "database is read-only",
        error.Sqlite => "database error",
        error.Interrupted => "it asked for more work than a call may do; ask for less",
        error.TooBig => "the answer is too large; ask for less",
        error.NotYet => "internal error: a filter's read escaped its batch",
    };

    std.debug.assert(text.len > 0);

    return text;
}

fn is_help_flag(flag: []const u8) bool {
    return std.mem.eql(u8, flag, "--help") or std.mem.eql(u8, flag, "-h");
}

fn write(out: *std.Io.Writer, text: []const u8) !void {
    try out.writeAll(text);
}

fn operation_name_args(args: []const []const u8) u32 {
    std.debug.assert(args.len > 0);
    std.debug.assert(args.len <= args_max);

    if (std.mem.indexOfScalar(u8, args[0], '.') != null) {
        return 1;
    }

    return 2;
}

fn operation_name(arena: std.mem.Allocator, args: []const []const u8) Error![]const u8 {
    std.debug.assert(args.len > 0);

    if (args[0].len == 0) {
        return error.UnknownOp;
    }

    if (operation_name_args(args) == 1) {
        return args[0];
    }

    if (args.len < 2) {
        return error.UnknownOp;
    }

    return std.fmt.allocPrint(arena, "{s}.{s}", .{ args[0], args[1] }) catch
        return error.OutOfMemory;
}

pub const ParseOptions = struct {
    /// A password read from the environment, used when no `--password` flag is given.
    password_env: ?[]const u8 = null,
};

pub fn parse_in(
    comptime In: type,
    arena: std.mem.Allocator,
    args: []const []const u8,
    problem: *Problem,
    options: ParseOptions,
) Error!In {
    comptime std.debug.assert(std.meta.fields(In).len <= sdk.operation.fields_max);

    if (args.len > args_max) {
        return error.Invalid;
    }

    var in: In = undefined;
    var seen: [std.meta.fields(In).len]bool = @splat(false);
    var index: u32 = 0;

    while (index < args.len) : (index += 2) {
        const flag = args[index];

        if (!std.mem.startsWith(u8, flag, "--")) {
            problem.set("unexpected argument \"{s}\"", .{flag});
            return error.UnknownFlag;
        }
        if (index + 1 == args.len) {
            problem.set("flag \"{s}\" needs a value", .{flag});
            return error.MissingValue;
        }

        const value = args[index + 1];
        var matched = false;

        inline for (std.meta.fields(In), 0..) |field, field_index| {
            if (std.mem.eql(u8, flag[2..], field.name)) {
                const parsed = parse_value(field.type, arena, value) catch {
                    problem.set("invalid value \"{s}\" for --{s} (expected {s})", .{
                        value,
                        field.name,
                        help.type_label(field.type),
                    });
                    return error.Invalid;
                };
                const list = comptime field.type == []const []const u8;

                // A list flag given again adds to the list (`--tags a --tags b`, and a
                // query's `tags=a&tags=b`), as a comma inside one value does.
                @field(in, field.name) = if (list and seen[field_index])
                    std.mem.concat(arena, []const u8, &.{ @field(in, field.name), parsed }) catch {
                        return error.OutOfMemory;
                    }
                else
                    parsed;
                seen[field_index] = true;
                matched = true;
            }
        }

        if (!matched) {
            problem.set("unknown flag \"{s}\"", .{flag});
            return error.UnknownFlag;
        }
    }

    inline for (std.meta.fields(In), 0..) |field, field_index| {
        if (!seen[field_index]) {
            const is_password = comptime std.mem.eql(u8, field.name, "password");
            const is_text = field.type == []const u8 or field.type == ?[]const u8;
            const from_env = is_password and is_text;
            if (from_env and options.password_env != null) {
                @field(in, field.name) = options.password_env.?;
            } else {
                const default = field.defaultValue() orelse {
                    problem.set("missing required --{s} ({s}){s}", .{
                        field.name,
                        help.type_label(field.type),
                        if (from_env) "; or set PUBLR_PASSWORD" else "",
                    });

                    return error.Invalid;
                };
                @field(in, field.name) = default;
            }
        }
    }

    return in;
}

fn resolve_user(invocation: Invocation, id_or_email: []const u8) Error!?sdk.Caller {
    std.debug.assert(id_or_email.len <= value_len_max);
    std.debug.assert(invocation.db.transaction_depth == 0);

    if (id_or_email.len == 0) {
        return null;
    }

    const user_module = @import("../store/users.zig");
    const found = if (std.mem.indexOfScalar(u8, id_or_email, '@') != null) blk: {
        const email = user_module.normalize_email(invocation.arena, id_or_email) catch return null;
        break :blk try user_module.find_by_email(invocation.db, invocation.arena, email);
    } else blk: {
        break :blk try user_module.find_by_id(invocation.db, invocation.arena, id_or_email);
    };

    const credentials = found orelse return null;

    return .{
        .user = .{
            .id = credentials.user.id,
            .roles = credentials.user.roles,
        },
    };
}

fn parse_value(comptime Value: type, arena: std.mem.Allocator, text: []const u8) Error!Value {
    if (text.len > value_len_max) {
        return error.Invalid;
    }

    return switch (@typeInfo(Value)) {
        .bool => if (std.mem.eql(
            u8,
            text,
            "true",
        )) true else if (std.mem.eql(
            u8,
            text,
            "false",
        )) false else error.Invalid,
        .int => std.fmt.parseInt(Value, text, 10) catch return error.Invalid,
        .float => blk: {
            const number = std.fmt.parseFloat(Value, text) catch return error.Invalid;
            break :blk if (std.math.isFinite(number)) number else error.Invalid;
        },
        .@"enum" => std.meta.stringToEnum(Value, text) orelse return error.Invalid,
        .optional => |optional| blk: {
            if (std.mem.eql(u8, text, "null")) {
                break :blk null;
            }

            break :blk try parse_value(optional.child, arena, text);
        },
        .pointer => |pointer| blk: {
            if (pointer.child == u8) {
                break :blk text;
            }

            if (comptime help.listable(pointer.child)) {
                break :blk try parse_list(pointer.child, arena, text);
            }

            break :blk try parse_json(Value, arena, text);
        },
        .@"struct" => blk: {
            if (comptime @hasDecl(Value, "reference")) {
                if (bare_id(text)) {
                    break :blk .{
                        .id = text,
                    };
                }
            }

            break :blk try parse_json(Value, arena, text);
        },
        .@"union" => try parse_json(Value, arena, text),
        else => @compileError("CLI cannot parse " ++ @typeName(Value)),
    };
}

/// A record named by its id as it is (`--variant 01a1…`, a form's field), not as JSON.
fn bare_id(text: []const u8) bool {
    std.debug.assert(text.len <= value_len_max);

    return text.len > 0 and text[0] != '"' and text[0] != '{';
}

fn parse_json(comptime Value: type, arena: std.mem.Allocator, text: []const u8) Error!Value {
    std.debug.assert(text.len <= value_len_max);

    return std.json.parseFromSliceLeaky(Value, arena, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Invalid,
    };
}

fn parse_list(
    comptime Value: type,
    arena: std.mem.Allocator,
    text: []const u8,
) Error![]const Value {
    if (text.len == 0) {
        return &.{};
    }

    // A JSON array, as `--commands` says lists are, and the only way to give a value with a
    // comma in it (an address); else values split at commas.
    if (text[0] == '[') {
        return parse_json([]const Value, arena, text);
    }

    const count = std.mem.count(u8, text, ",") + 1;
    var list = arena.alloc(Value, count) catch return error.OutOfMemory;
    var iterator = std.mem.splitScalar(u8, text, ',');
    var index: u32 = 0;

    while (iterator.next()) |part| : (index += 1) list[index] = try parse_value(Value, arena, part);

    std.debug.assert(index == count);

    return list;
}

test "parse_in takes a record by its bare id, or as JSON" {
    const Named = struct {
        title: []const u8,
    };
    const In = struct {
        variant: @import("../operations/record/typed.zig").Ref(Named, "variant"),
    };
    var problem: Problem = .{};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bare = try parse_in(In, arena, &.{ "--variant", "01a1b2" }, &problem, .{});
    const quoted = try parse_in(In, arena, &.{ "--variant", "\"01a1b2\"" }, &problem, .{});

    try std.testing.expectEqualStrings("01a1b2", bare.variant.id);
    try std.testing.expectEqualStrings("01a1b2", quoted.variant.id);
    const empty = parse_in(In, arena, &.{ "--variant", "" }, &problem, .{});

    try std.testing.expectError(error.Invalid, empty);
}

test "parse_in fills fields from flags and applies defaults" {
    const In = struct {
        name: []const u8,
        times: u32 = 1,
        tags: []const []const u8 = &.{},
        loud: bool = false,
    };
    var buffer: [1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);

    const arena = fixed.allocator();
    var problem: Problem = .{};
    const args = [_][]const u8{ "--name", "zig", "--tags", "a,b", "--loud", "true" };
    const in = try parse_in(In, arena, &args, &problem, .{});

    try std.testing.expectEqualStrings("zig", in.name);
    try std.testing.expectEqual(@as(u32, 1), in.times);
    try std.testing.expectEqual(@as(u32, 2), @as(u32, @intCast(in.tags.len)));
    try std.testing.expect(in.loud);

    const repeated = [_][]const u8{ "--name", "zig", "--tags", "a", "--tags", "b,c" };
    const again = try parse_in(In, arena, &repeated, &problem, .{});

    try std.testing.expectEqual(@as(u32, 3), @as(u32, @intCast(again.tags.len)));
    try std.testing.expectEqualStrings("c", again.tags[2]);

    // A JSON array keeps a comma inside a value.
    const as_json = [_][]const u8{ "--name", "zig", "--tags", "[\"a,b\",\"c\"]" };
    const listed = try parse_in(In, arena, &as_json, &problem, .{});

    try std.testing.expectEqual(@as(u32, 2), @as(u32, @intCast(listed.tags.len)));
    try std.testing.expectEqualStrings("a,b", listed.tags[0]);

    try std.testing.expectError(error.Invalid, parse_in(In, arena, &.{}, &problem, .{}));
    try std.testing.expectEqualStrings("missing required --name (text)", problem.text());
    const nope = [_][]const u8{ "--nope", "1" };
    try std.testing.expectError(error.UnknownFlag, parse_in(In, arena, &nope, &problem, .{}));
    try std.testing.expectEqualStrings("unknown flag \"--nope\"", problem.text());
    const missing_value = parse_in(In, arena, &.{"--name"}, &problem, .{});
    const bad_int = parse_in(In, arena, &.{ "--times", "x" }, &problem, .{});
    try std.testing.expectError(error.MissingValue, missing_value);
    try std.testing.expectError(error.Invalid, bad_int);
    const invalid = "invalid value \"x\" for --times (expected integer)";
    try std.testing.expectEqualStrings(invalid, problem.text());
}

test "run: --help lists operations, unknown operation, --as sets the caller, output is JSON" {
    const heartbeat = @import("../operations/heartbeat.zig");
    const SDK = sdk.SDK(.{
        .operations = &heartbeat.operations,
    });
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var out_buffer: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buffer);
    const connection = &harness.fixture.connection;
    const io = std.testing.io;
    const fixed = harness.fixed.allocator();
    const Command = CLI(SDK);

    var err_buffer: [512]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buffer);
    const with_err: Options = .{
        .err = &err,
    };
    const nope = [_][]const u8{ "nope", "verb" };
    const unknown = try Command.run(connection, io, fixed, &harness.auth, &nope, &out, with_err);
    try std.testing.expectEqual(@as(u8, 2), unknown);
    const message = err.buffered();
    try std.testing.expect(std.mem.indexOf(u8, message, "unknown command \"nope.verb\"") != null);

    const user_module = @import("../store/users.zig");
    const arena = harness.fixed.allocator();
    const user_id = try user_module.insert(&harness.fixture.connection, std.testing.io, arena, .{
        .email = "ed@example.com",
        .display_name = "Ed",
        .password_hash = "$argon2id$x",
        .roles = &.{"editor"},
        .now_ms = 0,
    });
    const args = [_][]const u8{ "--as", "ed@example.com", "heartbeat", "check", "--echo", "x" };
    const status = try Command.run(connection, io, fixed, &harness.auth, &args, &out, .{});
    try std.testing.expectEqual(@as(u8, 0), status);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), user_id) != null);

    err = .fixed(&err_buffer);
    const ghost = [_][]const u8{ "--as", "ghost", "heartbeat", "check" };
    const auth = &harness.auth;
    const unknown_user = try Command.run(connection, io, fixed, auth, &ghost, &out, with_err);
    try std.testing.expectEqual(@as(u8, 2), unknown_user);
    try std.testing.expect(std.mem.indexOf(u8, err.buffered(), "unknown user \"ghost\"") != null);

    out = .fixed(&out_buffer);
    const listed = try Command.run(connection, io, fixed, &harness.auth, &.{"--help"}, &out, .{});
    try std.testing.expectEqual(@as(u8, 0), listed);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "Usage: publr") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "heartbeat check") != null);

    out = .fixed(&out_buffer);
    const asked = [_][]const u8{ "heartbeat", "check", "--help" };
    const command_help = try Command.run(connection, io, fixed, &harness.auth, &asked, &out, .{});
    try std.testing.expectEqual(@as(u8, 0), command_help);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "--echo") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "optional") != null);
}

test "malformed CLI scalars and oversized input are validation errors" {
    const arena = std.testing.allocator;
    var problem: Problem = .{};
    const In = struct {
        flag: bool = false,
        number: f64 = 0,
        text: []const u8 = "",
    };

    for ([_][]const u8{ "yes", "1", "FALSE", "" }) |value| {
        try std.testing.expectError(
            error.Invalid,
            parse_in(
                In,
                arena,
                &.{
                    "--flag",
                    value,
                },
                &problem,
                .{},
            ),
        );
    }

    for ([_][]const u8{ "nan", "inf", "-inf", "1e999" }) |value| {
        try std.testing.expectError(
            error.Invalid,
            parse_in(
                In,
                arena,
                &.{
                    "--number",
                    value,
                },
                &problem,
                .{},
            ),
        );
    }

    const long = "x" ** (value_len_max + 1);
    try std.testing.expectError(
        error.Invalid,
        parse_in(
            In,
            arena,
            &.{
                "--text",
                long,
            },
            &problem,
            .{},
        ),
    );
    const many = [_][]const u8{"--flag"} ** (args_max + 1);
    try std.testing.expectError(error.Invalid, parse_in(In, arena, &many, &problem, .{}));
    const valid = try parse_in(
        In,
        arena,
        &.{
            "--flag",
            "false",
            "--number",
            "1.5",
        },
        &problem,
        .{},
    );
    try std.testing.expect(!valid.flag);
    try std.testing.expectEqual(@as(f64, 1.5), valid.number);
}

test "empty commands, oversized caller names and a full init alias fail gracefully" {
    const heartbeat = @import("../operations/heartbeat.zig");
    const Command = CLI(sdk.SDK(.{
        .operations = &heartbeat.operations,
    }));
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var output_buffer: [4096]u8 = undefined;
    var error_buffer: [4096]u8 = undefined;
    var output: std.Io.Writer = .fixed(&output_buffer);
    var errors: std.Io.Writer = .fixed(&error_buffer);
    const connection = &harness.fixture.connection;
    const io = std.testing.io;
    const fixed = harness.fixed.allocator();
    const options: Options = .{
        .err = &errors,
    };
    const empty = try Command.run(connection, io, fixed, &harness.auth, &.{""}, &output, options);
    try std.testing.expectEqual(@as(u8, 2), empty);
    const long = "x" ** (value_len_max + 1);
    const too_long = [_][]const u8{ "--as", long };
    const auth = &harness.auth;
    const long_as = try Command.run(connection, io, fixed, auth, &too_long, &output, options);
    try std.testing.expectEqual(@as(u8, 2), long_as);
    var alias: [args_max][]const u8 = @splat("--help");
    alias[0] = "init";
    const aliased = try Command.run(connection, io, fixed, &harness.auth, &alias, &output, options);
    try std.testing.expectEqual(@as(u8, 2), aliased);
}
