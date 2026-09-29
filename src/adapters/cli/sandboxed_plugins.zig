//! The commands installed plugins bring: flags read into JSON by the field shapes in the
//! plugin's manifest, the output printed as the other commands print theirs.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const sandboxed_plugin = @import("../../model/sandboxed_plugin.zig");
const cli = @import("../cli.zig");

const Error = cli.Error;
const Field = sandboxed_plugin.Field;

pub fn parse(
    arena: std.mem.Allocator,
    found: sdk.sandboxed_plugins.Operation,
    args: []const []const u8,
    problem: *cli.Problem,
) Error![]const u8 {
    std.debug.assert(found.fields.len <= sdk.operation.fields_max);
    std.debug.assert(args.len <= cli.args_max);

    var object: std.json.ObjectMap = .empty;
    var index: u32 = 0;

    while (index < args.len) : (index += 2) {
        const flag = args[index];

        if (!std.mem.startsWith(u8, flag, "--") or index + 1 == args.len) {
            problem.set("flag \"{s}\" needs a value", .{flag});
            return error.MissingValue;
        }

        const field = field_named(found.fields, flag[2..]) orelse {
            problem.set("unknown flag \"{s}\"", .{flag});
            return error.UnknownFlag;
        };
        const value = value_of(arena, field, args[index + 1]) catch {
            problem.set("\"{s}\" is not a {t}", .{ args[index + 1], field.shape });
            return error.Invalid;
        };

        try object.put(arena, field.name, value);
    }

    for (found.fields) |field| {
        if (field.required and !object.contains(field.name)) {
            problem.set("missing --{s}", .{field.name});
            return error.MissingValue;
        }
    }

    return std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = object }, .{}) catch {
        return error.OutOfMemory;
    };
}

fn field_named(fields: []const Field, name: []const u8) ?Field {
    std.debug.assert(fields.len <= sdk.operation.fields_max);

    for (fields) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            return field;
        }
    }

    return null;
}

fn value_of(arena: std.mem.Allocator, field: Field, text: []const u8) !std.json.Value {
    std.debug.assert(field.name.len > 0);
    std.debug.assert(text.len <= cli.value_len_max);

    return switch (field.shape) {
        .string => .{ .string = text },
        .integer => .{ .integer = try std.fmt.parseInt(i64, text, 10) },
        .number => .{ .float = try std.fmt.parseFloat(f64, text) },
        .boolean => .{ .bool = try parse_bool(text) },
        .strings => strings: {
            var list: std.json.Array = .init(arena);
            var parts = std.mem.splitScalar(u8, text, ',');

            while (parts.next()) |part| {
                try list.append(.{ .string = part });
            }

            break :strings .{ .array = list };
        },
        .json => try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}),
    };
}

fn parse_bool(text: []const u8) !bool {
    std.debug.assert(text.len <= cli.value_len_max);

    if (std.mem.eql(u8, text, "true")) {
        return true;
    }

    if (std.mem.eql(u8, text, "false")) {
        return false;
    }

    return error.Invalid;
}

pub fn print_json(arena: std.mem.Allocator, text: []const u8, out: *std.Io.Writer) Error!void {
    std.debug.assert(text.len > 0);

    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch {
        return error.Invalid;
    };

    const options: std.json.Stringify.Options = .{ .whitespace = .indent_2 };

    std.json.Stringify.value(value, options, out) catch return error.WriteFailed;
    out.writeByte('\n') catch return error.WriteFailed;
}

pub fn print_help(found: sdk.sandboxed_plugins.Operation, out: *std.Io.Writer) Error!void {
    std.debug.assert(found.name.len > 0);

    const namespace = sdk.operation.namespace(found.name);
    const verb = sdk.operation.verb(found.name);

    out.print("publr {s} {s}: {s}\n\nFields:\n\n", .{ namespace, verb, found.description }) catch
        return error.WriteFailed;

    for (found.fields) |field| {
        const presence = if (field.required) "required" else "optional";

        out.print("  --{s:<20} {t}, {s}  {s}\n", .{
            field.name,
            field.shape,
            presence,
            field.doc,
        }) catch return error.WriteFailed;
    }
}

/// `publr <namespace> --help` for a namespace an installed plugin brings: its summary and
/// details, then its commands. False when no loaded plugin declares it.
pub fn print_namespace_help(
    sandboxed: *const sdk.sandboxed_plugins.SandboxedPlugins,
    namespace: []const u8,
    out: *std.Io.Writer,
) Error!bool {
    std.debug.assert(namespace.len > 0);

    for (sandboxed.manifests()) |manifest| {
        for (manifest.namespaces) |documented| {
            if (!std.mem.eql(u8, documented.name, namespace)) {
                continue;
            }

            out.print("Usage: publr {s} <verb> [--field value ...]\n\n{s}\n\n{s}\n", .{
                namespace,
                documented.summary,
                documented.details,
            }) catch return error.WriteFailed;
            try print_commands(manifest, namespace, out);

            return true;
        }
    }

    return false;
}

fn print_commands(
    manifest: sandboxed_plugin.Manifest,
    namespace: []const u8,
    out: *std.Io.Writer,
) Error!void {
    std.debug.assert(namespace.len > 0);
    std.debug.assert(manifest.name.len > 0);

    out.print("\nCommands (installed plugin {s} {s}):\n\n", .{
        manifest.name,
        manifest.version,
    }) catch return error.WriteFailed;

    for (manifest.operations) |operation| {
        if (std.mem.eql(u8, sdk.operation.namespace(operation.name), namespace)) {
            out.print("  {s} {s:<20} {s}\n", .{
                namespace,
                sdk.operation.verb(operation.name),
                operation.description,
            }) catch return error.WriteFailed;
        }
    }

    out.print("\nRun `publr {s} <verb> --help` for the fields of a command.\n", .{namespace}) catch
        return error.WriteFailed;
}

test "flags become JSON by the field shapes; unknown and missing flags are named" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const found: sdk.sandboxed_plugins.Operation = .{
        .name = "greeter.greet",
        .kind = .write,
        .sandboxed_plugin = 0,
        .entry = 0,
        .fields = &.{
            .{ .name = "note", .shape = .string, .required = true },
            .{ .name = "times", .shape = .integer, .required = false },
            .{ .name = "tags", .shape = .strings, .required = false },
        },
    };
    var problem: cli.Problem = .{};

    const flags = [_][]const u8{ "--note", "hi", "--times", "3", "--tags", "a,b" };
    const text = try parse(arena, found, &flags, &problem);
    const expected = "{\"note\":\"hi\",\"times\":3,\"tags\":[\"a\",\"b\"]}";

    try std.testing.expectEqualStrings(expected, text);
    try std.testing.expectError(error.MissingValue, parse(arena, found, &.{}, &problem));
    try std.testing.expectEqualStrings("missing --note", problem.text());
    const unknown = parse(arena, found, &.{ "--nope", "x" }, &problem);

    try std.testing.expectError(error.UnknownFlag, unknown);
    try std.testing.expectError(error.Invalid, parse(arena, found, &.{ "--times", "x" }, &problem));
}
