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

    return std.json.Stringify.valueAlloc(arena, std.json.Value{
        .object = object,
    }, .{}) catch {
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
        for (try strings_of(arena, text)) |part| {
            try one_of(field.values, part);
        }
    } else if (field.values.len > 0 and !(is_null(field, text))) {
        try one_of(field.values, text);
    }

    if (is_null(field, text)) {
        return .null;
    }

    return switch (field.shape) {
        .string => .{
            .string = text,
        },
        .integer => .{
            .integer = try std.fmt.parseInt(i64, text, 10),
        },
        .number => .{
            .float = try std.fmt.parseFloat(f64, text),
        },
        .boolean => .{
            .bool = try parse_bool(text),
        },
        .strings => strings: {
            var list: std.json.Array = .init(arena);

            for (try strings_of(arena, text)) |part| {
                try list.append(.{
                    .string = part,
                });
            }

            break :strings .{
                .array = list,
            };
        },
        .json => try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}),
    };
}

/// A list of text as given: a JSON array (`["a","b"]`), else comma-separated (`a,b`), as a
/// compiled-in operation reads it.
fn strings_of(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    std.debug.assert(text.len <= cli.value_len_max);

    const trimmed = std.mem.trim(u8, text, " ");

    if (std.mem.startsWith(u8, trimmed, "[")) {
        return std.json.parseFromSliceLeaky([]const []const u8, arena, trimmed, .{});
    }

    var list: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, text, ',');

    while (parts.next()) |part| {
        try list.append(arena, part);
    }

    std.debug.assert(list.items.len > 0);

    return list.items;
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

    const options: std.json.Stringify.Options = .{
        .whitespace = .indent_2,
    };

    std.json.Stringify.value(value, options, out) catch return error.WriteFailed;
    out.writeByte('\n') catch return error.WriteFailed;
}

/// The `next` an answer names, when it answers a page at a time and there is a page after;
/// null otherwise.
pub fn next_of(arena: std.mem.Allocator, output: []const u8) ?[]const u8 {
    std.debug.assert(output.len > 0);

    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, output, .{}) catch {
        return null;
    };

    if (value != .object) {
        return null;
    }

    const next = value.object.get("next") orelse return null;

    return if (next == .string and next.string.len > 0) next.string else null;
}

/// The input as JSON with `after` set to `after`: the same call for the next page. Null
/// when the caller named a page itself, or the input is no object.
pub fn input_after(
    arena: std.mem.Allocator,
    input: []const u8,
    after: []const u8,
) Error!?[]const u8 {
    std.debug.assert(after.len > 0);

    var value = std.json.parseFromSliceLeaky(std.json.Value, arena, input, .{}) catch {
        return null;
    };

    if (value != .object) {
        return null;
    }

    if (value.object.get("after")) |given| {
        if (given != .string or given.string.len > 0) {
            return null;
        }
    }

    value.object.put(arena, "after", .{
        .string = after,
    }) catch return error.OutOfMemory;

    return std.json.Stringify.valueAlloc(arena, value, .{}) catch error.OutOfMemory;
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
            .{
                .name = "note",
                .shape = .string,
                .required = true,
                .label = "text",
            },
            .{
                .name = "times",
                .shape = .integer,
                .required = false,
                .label = "integer",
            },
            .{
                .name = "tags",
                .shape = .strings,
                .required = false,
                .label = "list of text",
            },
        },
    };
    var problem: cli.Problem = .{};

    const flags = [_][]const u8{ "--note", "hi", "--times", "3", "--tags", "a,b" };
    const text = try parse(arena, found, &flags, &problem);
    const expected = "{\"note\":\"hi\",\"times\":3,\"tags\":[\"a\",\"b\"]}";

    try std.testing.expectEqualStrings(expected, text);

    // A list of text given as a JSON array arrives as the same list.
    const as_json = [_][]const u8{ "--note", "hi", "--times", "3", "--tags", "[\"a\",\"b\"]" };

    try std.testing.expectEqualStrings(expected, try parse(arena, found, &as_json, &problem));
    try std.testing.expectError(error.Invalid, parse(arena, found, &.{}, &problem));
    try std.testing.expectEqualStrings("missing required --note (text)", problem.text());
    const unknown = parse(arena, found, &.{ "--nope", "x" }, &problem);

    try std.testing.expectError(error.UnknownFlag, unknown);
    try std.testing.expectError(error.Invalid, parse(arena, found, &.{ "--times", "x" }, &problem));
}
