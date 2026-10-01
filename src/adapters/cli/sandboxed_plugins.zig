//! The commands installed plugins bring: flags read into JSON by the field shapes in the
//! plugin's manifest, the output printed as the other commands print theirs.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const sandboxed_plugin = @import("../../model/sandboxed_plugin.zig");
const cli = @import("../cli.zig");

const Error = cli.Error;
const Field = sandboxed_plugin.Field;

/// The flags read into JSON by the manifest's fields, refused with the words a compiled-in
/// operation's are.
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

        if (!std.mem.startsWith(u8, flag, "--")) {
            problem.set("unexpected argument \"{s}\"", .{flag});
            return error.UnknownFlag;
        }

        if (index + 1 == args.len) {
            problem.set("flag \"{s}\" needs a value", .{flag});
            return error.MissingValue;
        }

        const text = args[index + 1];
        const field = field_named(found.fields, flag[2..]) orelse {
            problem.set("unknown flag \"{s}\"", .{flag});
            return error.UnknownFlag;
        };
        const value = value_of(arena, field, text) catch {
            problem.set("invalid value \"{s}\" for --{s} (expected {s})", .{
                text,
                field.name,
                field.label,
            });
            return error.Invalid;
        };

        try object.put(arena, field.name, value);
    }

    for (found.fields) |field| {
        if (field.required and !object.contains(field.name)) {
            problem.set("missing required --{s} ({s})", .{ field.name, field.label });
            return error.Invalid;
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

    if (field.values.len > 0 and std.mem.startsWith(u8, field.label, "list of ")) {
        var parts = std.mem.splitScalar(u8, text, ',');

        while (parts.next()) |part| {
            try one_of(field.values, part);
        }
    } else if (field.values.len > 0 and !(is_null(field, text))) {
        try one_of(field.values, text);
    }

    if (is_null(field, text)) {
        return .null;
    }

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

/// An optional field given `null`, as a compiled-in operation reads it.
fn is_null(field: Field, text: []const u8) bool {
    std.debug.assert(field.name.len > 0);

    return std.mem.endsWith(u8, field.label, "|null") and std.mem.eql(u8, text, "null");
}

fn one_of(values: []const []const u8, text: []const u8) !void {
    std.debug.assert(values.len > 0);

    for (values) |value| {
        if (std.mem.eql(u8, value, text)) {
            return;
        }
    }

    return error.Invalid;
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
    std.debug.assert(found.help.len > 0);

    out.writeAll(found.help) catch return error.WriteFailed;
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

    out.writeAll("\nCommands:\n\n") catch return error.WriteFailed;

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
            .{ .name = "note", .shape = .string, .required = true, .label = "text" },
            .{ .name = "times", .shape = .integer, .required = false, .label = "integer" },
            .{ .name = "tags", .shape = .strings, .required = false, .label = "list of text" },
        },
    };
    var problem: cli.Problem = .{};

    const flags = [_][]const u8{ "--note", "hi", "--times", "3", "--tags", "a,b" };
    const text = try parse(arena, found, &flags, &problem);
    const expected = "{\"note\":\"hi\",\"times\":3,\"tags\":[\"a\",\"b\"]}";

    try std.testing.expectEqualStrings(expected, text);
    try std.testing.expectError(error.Invalid, parse(arena, found, &.{}, &problem));
    try std.testing.expectEqualStrings("missing required --note (text)", problem.text());
    const unknown = parse(arena, found, &.{ "--nope", "x" }, &problem);

    try std.testing.expectError(error.UnknownFlag, unknown);
    try std.testing.expectError(error.Invalid, parse(arena, found, &.{ "--times", "x" }, &problem));
}
