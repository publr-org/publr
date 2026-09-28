const std = @import("std");
const sdk = @import("../sdk.zig");
const db = @import("../lib/db.zig");
const report = @import("../lib/report.zig");

pub const args_max: u32 = 128;
pub const value_len_max: u32 = 64 << 10;

pub const Error = sdk.Error || error{ UnknownOp, UnknownFlag, MissingValue, WriteFailed };

pub const Options = struct {
    db: *db.Db,
    io: std.Io,
    arena: std.mem.Allocator,
    auth: *AuthState,
    now_ms: i64 = 0,
    err: ?*std.Io.Writer = null,
    password_env: ?[]const u8 = null,
};

const AuthState = @import("../lib/auth.zig").State;

pub const message_len_max: u32 = 512;

pub fn CLI(comptime SDK: type) type {
    return struct {
        pub fn run(options: Options, args: []const []const u8, out: *std.Io.Writer) Error!u8 {
            @setEvalBranchQuota(100_000);

            if (args.len > args_max) {
                return fail(options, "too many arguments");
            }

            for (args) |arg| {
                if (arg.len > value_len_max) return fail(options, "argument is too long");
            }

            std.debug.assert(options.db.transaction_depth == 0);

            var caller: sdk.Caller = .anonymous;
            var index: u32 = 0;

            while (index < args.len and std.mem.startsWith(u8, args[index], "-")) : (index += 1) {
                const flag = args[index];

                if (std.mem.eql(u8, flag, "--as-admin")) {
                    caller = .system;
                } else if (std.mem.eql(u8, flag, "--as")) {
                    index += 1;
                    if (index == args.len) {
                        return fail(options, "flag \"--as\" needs a user id or email");
                    }
                    caller = try resolve_user(options, args[index]) orelse return failf(
                        options,
                        "unknown user \"{s}\"; --as takes a user id or email",
                        .{args[index]},
                    );
                } else if (is_help_flag(flag)) {
                    try print_help(out);
                    return 0;
                } else {
                    return failf(options, "unknown flag \"{s}\"; run \"publr --help\"", .{flag});
                }
            }

            if (index == args.len) {
                try print_help(out);
                return 2;
            }

            if (std.mem.eql(u8, args[index], "init")) {
                var aliased: [args_max + 1][]const u8 = undefined;
                const rest = args[index + 1 ..];
                if (rest.len > args_max - 2) return fail(options, "too many arguments");

                aliased[0] = "project";
                aliased[1] = "init";
                @memcpy(aliased[2 .. 2 + rest.len], rest);

                return dispatch_command(options, caller, aliased[0 .. 2 + rest.len], out);
            }

            return dispatch_command(options, caller, args[index..], out);
        }

        fn dispatch_command(
            options: Options,
            caller: sdk.Caller,
            args: []const []const u8,
            out: *std.Io.Writer,
        ) Error!u8 {
            @setEvalBranchQuota(100_000);

            std.debug.assert(args.len > 0);
            std.debug.assert(args.len <= args_max);

            if (args[0].len == 0) {
                return fail(options, "command must not be empty");
            }

            const index: u32 = 0;
            const bare_namespace = std.mem.indexOfScalar(u8, args[index], '.') == null and
                (index + 1 == args.len or is_help_flag(args[index + 1]));

            if (bare_namespace) {
                if (!namespace_known(args[index])) {
                    return failf(
                        options,
                        "unknown command \"{s}\"; commands are <namespace> <verb>, " ++
                            "run \"publr --help\"",
                        .{args[index]},
                    );
                }

                try print_namespace_help(args[index], out);

                return if (index + 1 == args.len) 2 else 0;
            }

            const name = operation_name(options.arena, args[index..]) catch |err| switch (err) {
                error.UnknownOp => return failf(
                    options,
                    "unknown command \"{s}\"; commands are <namespace> <verb>, " ++
                        "run \"publr --help\"",
                    .{args[index]},
                ),
                else => return err,
            };
            const rest = args[index + operation_name_args(args[index..]) ..];

            var ctx = sdk.Ctx.init(.{
                .caller = caller,
                .db = options.db,
                .io = options.io,
                .arena = options.arena,
                .auth = options.auth,
                .now_ms = options.now_ms,
            });

            inline for (SDK.operations) |Operation| {
                if (std.mem.eql(u8, Operation.name, name)) {
                    if (rest.len == 1 and is_help_flag(rest[0])) {
                        try print_command_help(Operation, out);
                        return 0;
                    }
                    return invoke(&ctx, Operation, rest, out, options);
                }
            }

            const namespace = sdk.operation.namespace(name);

            if (namespace_known(namespace)) {
                return failf(options, "unknown command \"{s} {s}\"; run \"publr {s} --help\"", .{
                    namespace,
                    sdk.operation.verb(name),
                    namespace,
                });
            }

            return failf(options, "unknown command \"{s}\"; run \"publr --help\"", .{name});
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

        fn invoke(
            ctx: *sdk.Ctx,
            comptime Operation: type,
            args: []const []const u8,
            out: *std.Io.Writer,
            options: Options,
        ) Error!u8 {
            var problem: Problem = .{};
            const password_env = options.password_env;
            const in = parse_in(Operation.In, ctx.arena, args, &problem, password_env) catch {
                return failf(options, "{s} {s}: {s}; run \"publr {s} {s} --help\"", .{
                    comptime sdk.operation.namespace(Operation.name),
                    comptime sdk.operation.verb(Operation.name),
                    problem.text(),
                    comptime sdk.operation.namespace(Operation.name),
                    comptime sdk.operation.verb(Operation.name),
                });
            };
            const result = SDK.dispatch(ctx, Operation, in) catch |err| {
                return failf(options, "{s} {s}: {s}", .{
                    comptime sdk.operation.namespace(Operation.name),
                    comptime sdk.operation.verb(Operation.name),
                    describe(err, ctx),
                });
            };

            std.json.Stringify.value(result, .{ .whitespace = .indent_2 }, out) catch
                return error.WriteFailed;
            out.writeByte('\n') catch return error.WriteFailed;

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

        fn print_command_help(comptime Operation: type, out: *std.Io.Writer) Error!void {
            @setEvalBranchQuota(100_000);

            const namespace = comptime sdk.operation.namespace(Operation.name);
            const verb = comptime sdk.operation.verb(Operation.name);
            const fields = std.meta.fields(Operation.In);
            const signature = if (fields.len == 0) "" else " [--field value ...]";

            comptime std.debug.assert(namespace.len > 0);
            comptime std.debug.assert(verb.len > 0);

            out.print("Usage: publr {s} {s}{s}\n\n{s}\n", .{
                namespace,
                verb,
                signature,
                Operation.description,
            }) catch return error.WriteFailed;

            if (@hasDecl(Operation, "details")) {
                out.print("\n{s}\n", .{Operation.details}) catch return error.WriteFailed;
            }

            if (fields.len > 0) {
                write(out, "\nFields:\n") catch return error.WriteFailed;
                try print_field_docs(Operation, Operation.In, "field_docs", true, out);
            }

            write(out, "\nOutput:\n") catch return error.WriteFailed;
            try print_field_docs(Operation, Operation.Out, "output_docs", false, out);
            try print_failures(Operation, out);
            try print_example(Operation, out);
        }

        /// The failures the operation declares beyond the core's errors, as REST names them.
        fn print_failures(comptime Operation: type, out: *std.Io.Writer) Error!void {
            comptime std.debug.assert(Operation.name.len > 0);

            if (!@hasDecl(Operation, "failures") or Operation.failures.len == 0) {
                return;
            }

            write(out, "\nFails with:\n") catch return error.WriteFailed;

            for (Operation.failures) |failure| {
                out.print("\n  {s} ({d})  {s}\n", .{
                    failure.name,
                    failure.status,
                    failure.message,
                }) catch return error.WriteFailed;
            }
        }

        fn print_field_docs(
            comptime Operation: type,
            comptime Shape: type,
            comptime docs_name: []const u8,
            comptime is_input: bool,
            out: *std.Io.Writer,
        ) Error!void {
            comptime std.debug.assert(docs_name.len > 0);
            comptime std.debug.assert(@typeInfo(Shape) == .@"struct");

            inline for (std.meta.fields(Shape)) |field| {
                const doc = comptime sdk.operation.field_doc(Operation, docs_name, field.name);
                const prefix = if (is_input) "--" else "";
                const presence = if (!is_input)
                    ""
                else if (field.defaultValue() == null)
                    "  (required)"
                else
                    "  (optional)";

                out.print("\n  {s}{s}  {s}{s}\n", .{
                    prefix,
                    field.name,
                    type_label(field.type),
                    presence,
                }) catch return error.WriteFailed;

                if (doc.len > 0) {
                    out.print("      {s}\n", .{doc}) catch return error.WriteFailed;
                }
            }
        }

        fn print_example(comptime Operation: type, out: *std.Io.Writer) Error!void {
            @setEvalBranchQuota(100_000);

            const namespace = comptime sdk.operation.namespace(Operation.name);
            const verb = comptime sdk.operation.verb(Operation.name);
            const anonymous_ok = sdk.authorize.is_open_operation(Operation.name) or
                (Operation.kind == .read and
                    sdk.authorize.is_public_read_namespace(Operation.name));
            const as: []const u8 = if (anonymous_ok) "" else "--as ada@example.com ";

            comptime std.debug.assert(namespace.len > 0);
            comptime std.debug.assert(verb.len > 0);

            out.print("\nExample:\n\n  $ publr {s}{s} {s}", .{ as, namespace, verb }) catch
                return error.WriteFailed;

            inline for (std.meta.fields(Operation.In)) |field| {
                const value = @field(Operation.example, field.name);
                const is_default = comptime blk: {
                    const default = field.defaultValue() orelse break :blk false;
                    break :blk std.meta.eql(default, value);
                };

                if (!is_default and !is_null(value)) {
                    out.print(" --{s} ", .{field.name}) catch return error.WriteFailed;
                    try print_example_value(value, out);
                }
            }

            write(out, "\n") catch return error.WriteFailed;

            var buffer: [8 << 10]u8 = undefined;
            var json: std.Io.Writer = .fixed(&buffer);
            const options: std.json.Stringify.Options = .{ .whitespace = .indent_2 };

            std.json.Stringify.value(Operation.example_out, options, &json) catch
                return error.WriteFailed;

            var lines = std.mem.splitScalar(u8, json.buffered(), '\n');

            while (lines.next()) |line| {
                out.print("  {s}\n", .{line}) catch return error.WriteFailed;
            }
        }

        /// A value as you would type it: JSON and anything with a space or a quote in it
        /// goes on one line inside single quotes, so the printed line can be pasted; text
        /// with an apostrophe (`Ada's App`) goes inside double quotes instead. An example
        /// with both an apostrophe and a character double quotes would expand is refused.
        fn print_example_text(text: []const u8, out: *std.Io.Writer) Error!void {
            std.debug.assert(text.len <= value_len_max);

            if (std.mem.indexOfScalar(u8, text, '\'') != null) {
                std.debug.assert(std.mem.indexOfAny(u8, text, "\"$`\\\n") == null);

                out.print("\"{s}\"", .{text}) catch return error.WriteFailed;

                return;
            }

            if (std.mem.indexOfAny(u8, text, " \"\n") == null) {
                write(out, text) catch return error.WriteFailed;

                return;
            }

            write(out, "'") catch return error.WriteFailed;

            var lines = std.mem.splitScalar(u8, text, '\n');

            while (lines.next()) |line| {
                write(out, line) catch return error.WriteFailed;
            }

            write(out, "'") catch return error.WriteFailed;
        }

        /// A list as you would type it: its items with commas between, no spaces.
        fn print_example_list(items: anytype, out: *std.Io.Writer) Error!void {
            std.debug.assert(items.len <= 64);
            std.debug.assert(items.len > 0);

            for (items, 0..) |item, index| {
                if (index > 0) {
                    write(out, ",") catch return error.WriteFailed;
                }

                try print_example_value(item, out);
            }
        }

        fn print_example_value(value: anytype, out: *std.Io.Writer) Error!void {
            const Value = @TypeOf(value);

            comptime std.debug.assert(@typeInfo(Value) != .void);

            switch (@typeInfo(Value)) {
                .bool => write(out, if (value) "true" else "false") catch return error.WriteFailed,
                .int, .float => out.print("{d}", .{value}) catch return error.WriteFailed,
                .@"enum" => write(out, @tagName(value)) catch return error.WriteFailed,
                .optional => try print_example_value(value.?, out),
                .pointer => |pointer| if (pointer.child == u8)
                    try print_example_text(value, out)
                else
                    try print_example_list(value, out),
                else => @compileError("example value: unsupported"),
            }
        }
    };
}

fn is_null(value: anytype) bool {
    const Value = @TypeOf(value);

    comptime std.debug.assert(@typeInfo(Value) != .void);

    return switch (@typeInfo(Value)) {
        .optional => value == null,
        else => false,
    };
}

const help_header =
    \\Usage: publr [--db <path>] [options] <namespace> <verb> [--field value ...]
    \\       publr init --email <email> --display_name <name>   first run: create the admin
    \\       publr serve [--port <n>]                            start the server
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
    \\for the fields of a command.
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

fn fail(options: Options, message: []const u8) u8 {
    std.debug.assert(message.len > 0);
    std.debug.assert(message.len <= message_len_max);

    if (options.err) |err| {
        err.print("publr: {s}\n", .{message}) catch |print_err| {
            std.debug.print("publr: {t}\n", .{print_err});
        };
    } else {
        report.err("publr: {s}", .{message});
    }

    return 2;
}

fn failf(options: Options, comptime format: []const u8, args: anytype) u8 {
    var buffer: [message_len_max]u8 = undefined;
    const message = report.format_bounded(&buffer, format, args);

    std.debug.assert(message.len > 0);
    std.debug.assert(message.len <= message_len_max);

    return fail(options, message);
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
        error.Throttled => "too many failed attempts; wait before trying again",
        error.Failed => if (ctx.failure) |failure| failure.message else "failed",
        error.Unavailable => "a service it needs is unavailable; nothing changed, try again",
        error.BadCredentials => "wrong email or password",
        error.InvalidationFailed => "dependency invalidation failed; write rolled back",
        error.OutOfMemory => "out of memory",
        error.Busy => "database is busy, try again",
        error.Constraint => "database constraint violated",
        error.ReadOnly => "database is read-only",
        error.Sqlite => "database error",
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

fn type_label(comptime Type: type) []const u8 {
    return type_label_depth(Type, 0);
}

fn type_label_depth(comptime Type: type, comptime depth: u32) []const u8 {
    @setEvalBranchQuota(100_000);

    if (depth > 3) {
        return "object";
    }

    const label: []const u8 = comptime switch (@typeInfo(Type)) {
        .bool => "true|false",
        .int => "integer",
        .float => "number",
        .@"enum" => |info| blk: {
            var joined: []const u8 = "";

            for (info.fields, 0..) |field, index| {
                joined = joined ++ (if (index == 0) "" else "|") ++ field.name;
            }

            break :blk joined;
        },
        .optional => |optional| type_label_depth(optional.child, depth + 1) ++ "|null",
        .pointer => |pointer| if (pointer.child == u8)
            "text"
        else
            "list of " ++ type_label_depth(pointer.child, depth + 1),
        .@"struct" => |info| blk: {
            var joined: []const u8 = "{ ";

            for (info.fields, 0..) |field, index| {
                const separator = if (index == 0) "" else ", ";
                joined = joined ++ separator ++ field.name ++ ": " ++ type_label_depth(
                    field.type,
                    depth + 1,
                );
            }

            break :blk joined ++ " }";
        },
        else => "value",
    };

    comptime std.debug.assert(label.len > 0);
    comptime std.debug.assert(label.len < 4096);

    return label;
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

pub fn parse_in(
    comptime In: type,
    arena: std.mem.Allocator,
    args: []const []const u8,
    problem: *Problem,
    password_env: ?[]const u8,
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
                @field(in, field.name) = parse_value(field.type, arena, value) catch {
                    problem.set("invalid value \"{s}\" for --{s} (expected {s})", .{
                        value,
                        field.name,
                        type_label(field.type),
                    });
                    return error.Invalid;
                };
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
            if (from_env and password_env != null) {
                @field(in, field.name) = password_env.?;
            } else {
                const default = field.defaultValue() orelse {
                    problem.set("missing required --{s} ({s}){s}", .{
                        field.name,
                        type_label(field.type),
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

fn resolve_user(options: Options, id_or_email: []const u8) Error!?sdk.Caller {
    std.debug.assert(id_or_email.len <= value_len_max);
    std.debug.assert(options.db.transaction_depth == 0);

    if (id_or_email.len == 0) {
        return null;
    }

    const user_module = @import("../store/users.zig");
    const found = if (std.mem.indexOfScalar(u8, id_or_email, '@') != null) blk: {
        const email = user_module.normalize_email(options.arena, id_or_email) catch return null;
        break :blk try user_module.find_by_email(options.db, options.arena, email);
    } else blk: {
        break :blk try user_module.find_by_id(options.db, options.arena, id_or_email);
    };

    const credentials = found orelse return null;

    return .{ .user = .{ .id = credentials.user.id, .roles = credentials.user.roles } };
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

            break :blk try parse_list(pointer.child, arena, text);
        },
        else => @compileError("CLI cannot parse " ++ @typeName(Value)),
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

    const count = std.mem.count(u8, text, ",") + 1;
    var list = arena.alloc(Value, count) catch return error.OutOfMemory;
    var iterator = std.mem.splitScalar(u8, text, ',');
    var index: u32 = 0;

    while (iterator.next()) |part| : (index += 1) list[index] = try parse_value(Value, arena, part);

    std.debug.assert(index == count);

    return list;
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
    const in = try parse_in(In, arena, &args, &problem, null);

    try std.testing.expectEqualStrings("zig", in.name);
    try std.testing.expectEqual(@as(u32, 1), in.times);
    try std.testing.expectEqual(@as(u32, 2), @as(u32, @intCast(in.tags.len)));
    try std.testing.expect(in.loud);

    try std.testing.expectError(error.Invalid, parse_in(In, arena, &.{}, &problem, null));
    try std.testing.expectEqualStrings("missing required --name (text)", problem.text());
    const nope = [_][]const u8{ "--nope", "1" };
    try std.testing.expectError(error.UnknownFlag, parse_in(In, arena, &nope, &problem, null));
    try std.testing.expectEqualStrings("unknown flag \"--nope\"", problem.text());
    const missing_value = parse_in(In, arena, &.{"--name"}, &problem, null);
    const bad_int = parse_in(In, arena, &.{ "--times", "x" }, &problem, null);
    try std.testing.expectError(error.MissingValue, missing_value);
    try std.testing.expectError(error.Invalid, bad_int);
    const invalid = "invalid value \"x\" for --times (expected integer)";
    try std.testing.expectEqualStrings(invalid, problem.text());
}

test "run: --help lists operations, unknown operation, --as sets the caller, output is JSON" {
    const heartbeat = @import("../operations/heartbeat.zig");
    const SDK = sdk.SDK(.{ .operations = &heartbeat.operations });
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var out_buffer: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buffer);
    const options: Options = .{
        .db = &harness.fixture.connection,
        .io = std.testing.io,
        .arena = harness.fixed.allocator(),
        .auth = &harness.auth,
    };
    const Command = CLI(SDK);

    var err_buffer: [512]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buffer);
    var options_with_err = options;
    options_with_err.err = &err;
    const unknown = try Command.run(options_with_err, &.{ "nope", "verb" }, &out);
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
    const status = try Command.run(options, &args, &out);
    try std.testing.expectEqual(@as(u8, 0), status);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), user_id) != null);

    err = .fixed(&err_buffer);
    const ghost = [_][]const u8{ "--as", "ghost", "heartbeat", "check" };
    const unknown_user = try Command.run(options_with_err, &ghost, &out);
    try std.testing.expectEqual(@as(u8, 2), unknown_user);
    try std.testing.expect(std.mem.indexOf(u8, err.buffered(), "unknown user \"ghost\"") != null);

    out = .fixed(&out_buffer);
    try std.testing.expectEqual(@as(u8, 0), try Command.run(options, &.{"--help"}, &out));
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "Usage: publr") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "heartbeat check") != null);

    out = .fixed(&out_buffer);
    const command_help = try Command.run(options, &.{ "heartbeat", "check", "--help" }, &out);
    try std.testing.expectEqual(@as(u8, 0), command_help);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "--echo") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "optional") != null);
}

test "malformed CLI scalars and oversized input are validation errors" {
    const arena = std.testing.allocator;
    var problem: Problem = .{};
    const In = struct { flag: bool = false, number: f64 = 0, text: []const u8 = "" };

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
                null,
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
                null,
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
            null,
        ),
    );
    const many = [_][]const u8{"--flag"} ** (args_max + 1);
    try std.testing.expectError(error.Invalid, parse_in(In, arena, &many, &problem, null));
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
        null,
    );
    try std.testing.expect(!valid.flag);
    try std.testing.expectEqual(@as(f64, 1.5), valid.number);
}

test "empty commands, oversized caller names and a full init alias fail gracefully" {
    const heartbeat = @import("../operations/heartbeat.zig");
    const Command = CLI(sdk.SDK(.{ .operations = &heartbeat.operations }));
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var output_buffer: [4096]u8 = undefined;
    var error_buffer: [4096]u8 = undefined;
    var output: std.Io.Writer = .fixed(&output_buffer);
    var errors: std.Io.Writer = .fixed(&error_buffer);
    const options: Options = .{
        .db = &harness.fixture.connection,
        .io = std.testing.io,
        .arena = harness.fixed.allocator(),
        .auth = &harness.auth,
        .err = &errors,
    };
    try std.testing.expectEqual(@as(u8, 2), try Command.run(options, &.{""}, &output));
    const long = "x" ** (value_len_max + 1);
    try std.testing.expectEqual(@as(u8, 2), try Command.run(options, &.{ "--as", long }, &output));
    var alias: [args_max][]const u8 = @splat("--help");
    alias[0] = "init";
    try std.testing.expectEqual(@as(u8, 2), try Command.run(options, &alias, &output));
}

test "an example value prints the way a shell reads it, apostrophes inside double quotes" {
    const heartbeat = @import("../operations/heartbeat.zig");
    const Command = CLI(sdk.SDK(.{ .operations = &heartbeat.operations }));
    var buffer: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);

    try Command.print_example_text("plain", &out);
    try out.writeByte(' ');
    try Command.print_example_text("two words", &out);
    try out.writeByte(' ');
    try Command.print_example_text("Ada's App", &out);
    try std.testing.expectEqualStrings("plain 'two words' \"Ada's App\"", out.buffered());
}
